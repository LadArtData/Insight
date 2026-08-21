#!/usr/bin/env python3
"""
Tests for INSIGHT_chat_proxy.py's request/response handling, with the
actual OCI call (call_llm) mocked out -- these verify the proxy's own
logic (validation, JSON parsing, fallback-on-malformed-response, error
handling) without needing real OCI credentials. The one thing these
CANNOT verify is that the real OCI SDK call in call_llm() itself is
correct against a live endpoint -- that needs real credentials, which
this environment doesn't have (see the module docstring in
INSIGHT_chat_proxy.py).

Run: python -m unittest test_INSIGHT_chat_proxy -v
"""

import json
import os
import unittest
from unittest import mock

import INSIGHT_chat_proxy as proxy


class ParseLlmResponseTests(unittest.TestCase):
    def test_valid_json_yn(self):
        raw = json.dumps({"assistantReply": "Got it, thanks!", "interpretedAnswer": "Yes"})
        result = proxy.parse_llm_response(raw)
        self.assertEqual(result, {"assistantReply": "Got it, thanks!", "interpretedAnswer": "Yes"})

    def test_valid_json_with_surrounding_whitespace(self):
        raw = "  \n" + json.dumps({"assistantReply": "Noted.", "interpretedAnswer": "No"}) + "\n"
        result = proxy.parse_llm_response(raw)
        self.assertEqual(result["interpretedAnswer"], "No")

    def test_malformed_json_falls_back_to_unclear(self):
        result = proxy.parse_llm_response("this is not json at all")
        self.assertEqual(result["interpretedAnswer"], "UNCLEAR")

    def test_missing_fields_falls_back_to_unclear(self):
        raw = json.dumps({"assistantReply": "Hi"})  # no interpretedAnswer
        result = proxy.parse_llm_response(raw)
        self.assertEqual(result["interpretedAnswer"], "UNCLEAR")

    def test_wrong_types_falls_back_to_unclear(self):
        raw = json.dumps({"assistantReply": "Hi", "interpretedAnswer": 123})
        result = proxy.parse_llm_response(raw)
        self.assertEqual(result["interpretedAnswer"], "UNCLEAR")


class BuildPromptTests(unittest.TestCase):
    def test_includes_question_and_user_message(self):
        gap_context = {"eyebrow": "Phase 2 · Scoping", "questionText": "Do you use AP?", "answerType": "yn"}
        prompt = proxy.build_prompt(gap_context, "yeah we do")
        self.assertIn("Do you use AP?", prompt)
        self.assertIn("Phase 2 · Scoping", prompt)
        self.assertIn("yeah we do", prompt)
        self.assertIn("yn", prompt)


class ChatRouteTests(unittest.TestCase):
    def setUp(self):
        proxy.app.testing = True
        self.client = proxy.app.test_client()

    def valid_body(self, **overrides):
        body = {
            "gapContext": {
                "eyebrow": "Phase 2 · Needs & Wants",
                "questionText": "Does the organization process vendor invoices?",
                "answerType": "yn",
            },
            "userMessage": "yes we do",
        }
        body.update(overrides)
        return body

    def test_health(self):
        resp = self.client.get("/health")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.get_json(), {"ok": True})

    def test_missing_json_body(self):
        resp = self.client.post("/chat", data="not json", content_type="text/plain")
        self.assertEqual(resp.status_code, 400)

    def test_missing_gap_context_fields(self):
        resp = self.client.post("/chat", json={"gapContext": {}, "userMessage": "hi"})
        self.assertEqual(resp.status_code, 400)
        self.assertIn("eyebrow", resp.get_json()["error"])

    def test_missing_user_message(self):
        body = self.valid_body()
        del body["userMessage"]
        resp = self.client.post("/chat", json=body)
        self.assertEqual(resp.status_code, 400)

    def test_invalid_answer_type(self):
        body = self.valid_body()
        body["gapContext"]["answerType"] = "essay"
        resp = self.client.post("/chat", json=body)
        self.assertEqual(resp.status_code, 400)

    def test_user_message_too_long(self):
        body = self.valid_body(userMessage="x" * 501)
        resp = self.client.post("/chat", json=body)
        self.assertEqual(resp.status_code, 400)

    @mock.patch("INSIGHT_chat_proxy.call_llm")
    def test_successful_call_returns_parsed_response(self, mock_call_llm):
        mock_call_llm.return_value = json.dumps(
            {"assistantReply": "Great, noted!", "interpretedAnswer": "Yes"}
        )
        resp = self.client.post("/chat", json=self.valid_body())
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.get_json(), {"assistantReply": "Great, noted!", "interpretedAnswer": "Yes"})
        mock_call_llm.assert_called_once()

    @mock.patch("INSIGHT_chat_proxy.call_llm")
    def test_llm_failure_returns_502_not_a_crash(self, mock_call_llm):
        mock_call_llm.side_effect = RuntimeError("simulated OCI outage")
        resp = self.client.post("/chat", json=self.valid_body())
        self.assertEqual(resp.status_code, 502)
        self.assertIn("error", resp.get_json())

    @mock.patch("INSIGHT_chat_proxy.call_llm")
    def test_malformed_llm_output_still_returns_200_with_unclear(self, mock_call_llm):
        mock_call_llm.return_value = "I am not JSON"
        resp = self.client.post("/chat", json=self.valid_body())
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.get_json()["interpretedAnswer"], "UNCLEAR")

    @mock.patch("INSIGHT_chat_proxy.call_llm")
    def test_call_llm_failure_of_any_kind_returns_502_not_a_process_exit(self, mock_call_llm):
        # Regression test for a bug found by actually running this against
        # a container with no OCI credentials configured: require_env()
        # must raise a catchable exception. It used to reuse env(...,
        # required=True), which calls sys.exit() -- SystemExit isn't
        # caught by `except Exception` in the chat() route, so a missing
        # OCI_COMPARTMENT_ID/OCI_GENAI_MODEL_ID on a single request would
        # blow past error handling instead of cleanly failing just that
        # request. This exercises the route's handling of exactly the
        # exception require_env() now raises.
        mock_call_llm.side_effect = RuntimeError("Missing required environment variable: OCI_GENAI_MODEL_ID")
        resp = self.client.post("/chat", json=self.valid_body())
        self.assertEqual(resp.status_code, 502)


class RequireEnvTests(unittest.TestCase):
    def test_raises_catchable_exception_not_systemexit(self):
        with mock.patch.dict("os.environ", {}, clear=True):
            with self.assertRaises(RuntimeError):
                proxy.require_env("OCI_GENAI_MODEL_ID")

    def test_returns_value_when_set(self):
        with mock.patch.dict("os.environ", {"OCI_GENAI_MODEL_ID": "ocid1.x"}, clear=False):
            self.assertEqual(proxy.require_env("OCI_GENAI_MODEL_ID"), "ocid1.x")


if __name__ == "__main__":
    unittest.main()


class ModelDefaultsTests(unittest.TestCase):
    """The model and compartment are baked in, so the service runs unconfigured."""

    def test_model_and_compartment_default_without_env(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertTrue(
                proxy.require_env("OCI_GENAI_MODEL_ID", proxy.DEFAULT_MODEL_ID)
                .startswith("ocid1.generativeaimodel.oc1.us-chicago-1.")
            )
            self.assertTrue(
                proxy.require_env("OCI_COMPARTMENT_ID", proxy.DEFAULT_COMPARTMENT_ID)
                .startswith("ocid1.tenancy.oc1..")
            )

    def test_env_overrides_the_baked_in_default(self):
        with mock.patch.dict(os.environ, {"OCI_GENAI_MODEL_ID": "ocid1.other"}, clear=True):
            self.assertEqual(
                proxy.require_env("OCI_GENAI_MODEL_ID", proxy.DEFAULT_MODEL_ID),
                "ocid1.other",
            )

    def test_still_raises_when_no_value_and_no_default(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(RuntimeError):
                proxy.require_env("OCI_SOMETHING_UNSET")
