#!/usr/bin/env python3
"""
INSIGHT_chat_proxy.py

Small server-side proxy in front of OCI Generative AI Inference, so the
browser-side AI Follow-Up chat (INSIGHT_app.html) can get real LLM replies
without ever holding OCI API credentials itself -- OCI request signing
needs a private key, and a private key can never ship to client-side JS.

The browser calls POST /chat on this service; this service holds the OCI
config (via ~/.oci/config, same as any OCI SDK client) and does the signed
call server-side, returning only the model's interpreted reply.

Modeled directly on the OCI Java SDK sample provided for this project
(ChatExample.java) -- GenericChatRequest + OnDemandServingMode, same
request shape, translated to the OCI Python SDK's parallel API. The
message-construction API surface here is deliberately limited to exactly
what that sample demonstrated (UserMessage + TextContent); nothing here
assumes SDK classes/fields the sample didn't show, since that can't be
verified without a live SDK install and real credentials (neither
available in the environment this was written in).

Configuration (env vars, matching this project's docker/.env convention):
  OCI_AUTH_METHOD          auto (default) | config_file | instance_principal.
                            auto uses ~/.oci/config when present, otherwise
                            instance principals -- so the same file works on
                            a laptop and inside the OCI container with no
                            change.
  OCI_CONFIG_PROFILE       Profile name in ~/.oci/config (default: DEFAULT)
  OCI_CONFIG_FILE          Path to the config file (default: ~/.oci/config)
  OCI_COMPARTMENT_ID       Compartment OCID with Generative AI access
                            (defaults to the project tenancy below)
  OCI_GENAI_MODEL_ID       Model OCID for OnDemandServingMode (defaults to
                            the model below)
  OCI_GENAI_ENDPOINT       Inference endpoint (default: the us-chicago-1
                            endpoint from the sample -- override if your
                            model lives in a different region)
  CHAT_PROXY_HOST          Interface to bind (default: 127.0.0.1 --
                            loopback only, because in the deployed container
                            nginx is the only thing that should reach this;
                            set 0.0.0.0 to run it as a standalone service)
  CHAT_PROXY_PORT          Port to listen on (default: 5001)

Run directly:
    pip install -r INSIGHT_chat_proxy_requirements.txt
    export OCI_COMPARTMENT_ID=...
    export OCI_GENAI_MODEL_ID=...
    python3 INSIGHT_chat_proxy.py
"""

import json
import os
import sys

from flask import Flask, jsonify, request

DEFAULT_ENDPOINT = "https://inference.generativeai.us-chicago-1.oci.oraclecloud.com"

# The model and compartment this project targets, taken from the OCI
# Generative AI ChatExample supplied for INSIGHT. Neither is a credential --
# an OCID names a resource, and reaching it still requires OCI auth and a
# policy granting Generative AI access -- so they are safe to keep here, and
# baking them in means the service needs no configuration to run.
#
# Served through GenericChatRequest rather than CohereChatRequest, which is
# how OCI exposes the non-Cohere families (Llama and similar). If the model
# is ever switched to a Cohere one, the request class has to change too --
# they are not interchangeable.
DEFAULT_MODEL_ID = (
    "ocid1.generativeaimodel.oc1.us-chicago-1."
    "amaaaaaask7dceyayjawvuonfkw2ua4bob4rlnnlhs522pafbglivtwlfzta"
)
DEFAULT_COMPARTMENT_ID = (
    "ocid1.tenancy.oc1..aaaaaaaatznhqzbky6jdvflzkfvedppvrxbw4weyi2japj37aoagj6kcbfoa"
)

app = Flask(__name__)

_client = None  # lazily constructed real OCI client; None until first real call


def env(name, default=None, required=False):
    """
    For startup-time config only (see __main__ below) -- sys.exit() on a
    missing required value is correct there (fail before serving any
    requests). NOT used for per-request config lookups inside call_llm();
    use require_env() there instead, since sys.exit() raises SystemExit,
    which bypasses `except Exception` and would blow past the chat()
    route's error handling instead of cleanly failing that one request.
    """
    val = os.environ.get(name, default)
    if required and not val:
        sys.exit(f"Missing required environment variable: {name}")
    return val


def require_env(name, default=None):
    """
    Per-request config lookup. Raises rather than sys.exit()ing so a missing
    value fails one request instead of the process -- see env() above.
    A default makes the value optional: the caller has a sensible built-in.
    """
    val = os.environ.get(name) or default
    if not val:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return val


def get_oci_client():
    """
    Builds (and caches) the OCI GenerativeAiInferenceClient. Import is
    local to this function so the rest of the module -- and every route's
    request/response handling -- can be unit tested without the `oci`
    package needing real credentials to even import cleanly.
    """
    global _client
    if _client is not None:
        return _client

    import oci  # local import -- see docstring above

    endpoint = env("OCI_GENAI_ENDPOINT", DEFAULT_ENDPOINT)
    mode = env("OCI_AUTH_METHOD", "auto").lower()

    # Two ways in, because the two places this runs cannot share one.
    #
    #   config file        a developer laptop, where ~/.oci/config exists.
    #                      This is what the Java sample uses.
    #   instance principal a Container Instance, which has no home
    #                      directory to mount a key into. OCI hands the
    #                      container an identity directly, so no secret is
    #                      stored or shipped anywhere.
    #
    # "auto" prefers the config file when one is present and falls back to
    # instance principals, so the same image runs in both places untouched.
    # Instance principals additionally require a dynamic group matching the
    # container and a policy granting it use of generative-ai-family.
    config_file = env("OCI_CONFIG_FILE", os.path.expanduser("~/.oci/config"))
    profile = env("OCI_CONFIG_PROFILE", "DEFAULT")
    use_config_file = mode == "config_file" or (mode == "auto" and os.path.exists(config_file))

    if use_config_file:
        config = oci.config.from_file(file_location=config_file, profile_name=profile)
        signer = None
        auth_used = "config_file"
    else:
        signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
        config = {}
        auth_used = "instance_principal"

    client_kwargs = {"service_endpoint": endpoint}
    if signer is not None:
        client_kwargs["signer"] = signer

    print(f"[chat-proxy] OCI auth: {auth_used}", flush=True)
    _client = oci.generative_ai_inference.GenerativeAiInferenceClient(
        config,
        **client_kwargs,
        # Matches the Java sample's 240s read timeout / no-retry config --
        # generative model calls are slow and a mid-call retry would
        # double-charge/double-generate rather than help.
        timeout=(10, 240),
    )
    return _client


# The model is asked to reply with strict JSON so this service can extract
# a structured answer without its own NLP -- the model does the
# interpretation (is this a yes, a no, or unclear?), this service just
# parses what it says. If the model doesn't cooperate (wrong format, or a
# genuinely ambiguous reply), PARSE_FALLBACK below treats it as "unclear"
# rather than guessing -- an unclear interpretation asks the user a
# clarifying follow-up instead of silently recording the wrong answer.
SYSTEM_FRAMING = """You are the "INSIGHT Assistant," helping a consulting team fill in gaps \
left in an Oracle Fusion Financials discovery questionnaire. You will be given one specific \
question that still needs an answer, and the user's latest reply. Your job:

1. Decide whether the reply actually answers the question.
2. Write a brief, professional, conversational acknowledgment (1-2 sentences) to show the user \
next -- natural, not robotic, no need to repeat the question back verbatim.
3. If the question type is "yn" (yes/no): interpret the reply as exactly "Yes", "No", or \
"UNCLEAR" if the reply doesn't clearly answer yes or no (ask a brief clarifying question in your \
acknowledgment when this happens, don't guess).
4. If the question type is "text": interpretedAnswer is the substance of their reply as a clean, \
well-formed sentence (correct obvious typos, don't invent information they didn't provide). If \
the reply doesn't actually address the question (e.g. off-topic, or asks something back), use \
"UNCLEAR" and ask a clarifying question in your acknowledgment instead.

Respond with ONLY a JSON object, no other text, in exactly this shape:
{"assistantReply": "...", "interpretedAnswer": "..."}"""


def build_prompt(gap_context, user_message):
    question_block = (
        f'Question ({gap_context["answerType"]} type): "{gap_context["eyebrow"]} '
        f'— {gap_context["questionText"]}"'
    )
    return f"{SYSTEM_FRAMING}\n\n{question_block}\n\nUser's reply: \"{user_message}\""


def parse_llm_response(raw_text):
    """
    Parses the model's JSON reply. Falls back to UNCLEAR (never guesses a
    Yes/No/answer the model didn't actually give) if the model didn't
    return valid, complete JSON -- a malformed response should surface as
    "let's clarify," not as a silently wrong stored answer.
    """
    try:
        parsed = json.loads(raw_text.strip())
        reply = parsed.get("assistantReply")
        answer = parsed.get("interpretedAnswer")
        if not isinstance(reply, str) or not isinstance(answer, str):
            raise ValueError("missing expected fields")
        return {"assistantReply": reply, "interpretedAnswer": answer}
    except (json.JSONDecodeError, ValueError, AttributeError):
        return {
            "assistantReply": "Sorry, could you rephrase that? I want to make sure I capture this correctly.",
            "interpretedAnswer": "UNCLEAR",
        }


def call_llm(gap_context, user_message):
    """
    The one function that actually talks to OCI. Kept separate from the
    Flask route (below) so tests can monkeypatch just this function and
    exercise the route's request validation / response handling without
    ever constructing a real OCI client.
    """
    import oci  # local import -- see get_oci_client()

    client = get_oci_client()
    prompt = build_prompt(gap_context, user_message)

    chat_request = oci.generative_ai_inference.models.GenericChatRequest()
    chat_request.messages = [
        oci.generative_ai_inference.models.UserMessage(
            role="USER",
            content=[oci.generative_ai_inference.models.TextContent(text=prompt)],
        )
    ]
    chat_request.max_tokens = 600
    # The supplied ChatExample uses temperature 1.0. Deliberately lower here:
    # that sample is a free-form text demo, whereas every call this service
    # makes is structured extraction -- read an answer, decide which question
    # it belongs to, return JSON. High temperature on that job produces
    # inconsistent field mapping between otherwise identical inputs, which is
    # the one failure mode a handoff format cannot tolerate. Every other
    # generation parameter matches the sample exactly.
    chat_request.temperature = 0.2
    chat_request.frequency_penalty = 0
    chat_request.presence_penalty = 0
    chat_request.top_p = 0.75
    chat_request.is_stream = False

    chat_detail = oci.generative_ai_inference.models.ChatDetails()
    chat_detail.serving_mode = oci.generative_ai_inference.models.OnDemandServingMode(
        model_id=require_env("OCI_GENAI_MODEL_ID", DEFAULT_MODEL_ID)
    )
    chat_detail.compartment_id = require_env("OCI_COMPARTMENT_ID", DEFAULT_COMPARTMENT_ID)
    chat_detail.chat_request = chat_request

    response = client.chat(chat_detail)
    # Response shape mirrors the request: response.data.chat_response.choices[0].message...
    # -- matches the Java sample's ChatResponse; exact accessor verified
    # against the SDK once real credentials are available (see module
    # docstring).
    raw_text = response.data.chat_response.choices[0].message.content[0].text
    return raw_text


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"ok": True})


@app.route("/chat", methods=["POST"])
def chat():
    body = request.get_json(silent=True)
    if not body:
        return jsonify({"error": "Request body must be JSON"}), 400

    gap_context = body.get("gapContext") or {}
    user_message = body.get("userMessage")

    missing = [
        k for k in ("eyebrow", "questionText", "answerType") if not gap_context.get(k)
    ]
    if missing or not user_message:
        return jsonify({"error": f"Missing required field(s): {', '.join(missing + (['userMessage'] if not user_message else []))}"}), 400
    if gap_context["answerType"] not in ("yn", "text"):
        return jsonify({"error": 'answerType must be "yn" or "text"'}), 400
    if len(user_message) > 500:
        return jsonify({"error": "userMessage exceeds 500 characters"}), 400

    try:
        raw_text = call_llm(gap_context, user_message)
    except Exception as exc:  # noqa: BLE001 -- deliberately broad: any OCI/network
        # failure should surface as a clean 502 to the front end, which
        # already has a showFatalError() path for exactly this.
        app.logger.error("OCI Generative AI call failed: %s", exc)
        return jsonify({"error": "The AI assistant is temporarily unavailable. Please try again."}), 502

    return jsonify(parse_llm_response(raw_text))


if __name__ == "__main__":
    # Loopback by default. In the deployed container only nginx talks to
    # this service, and binding every interface would expose an unauthenticated
    # endpoint that spends money on model calls to anything that can route to
    # the container.
    host = env("CHAT_PROXY_HOST", "127.0.0.1")
    port = int(env("CHAT_PROXY_PORT", "5001"))

    # Flask's built-in server is single-threaded and explicitly not for
    # production; a second request would queue behind a model call that can
    # take tens of seconds. waitress is a pure-Python WSGI server, so it adds
    # a dependency but no build toolchain. Fall back only so the file still
    # runs for local poking without the full requirements installed.
    try:
        from waitress import serve
    except ImportError:
        print(
            "[chat-proxy] waitress not installed; using Flask's development "
            "server. Do not run this way in a deployment.",
            file=sys.stderr,
            flush=True,
        )
        app.run(host=host, port=port)
    else:
        print(f"[chat-proxy] listening on {host}:{port}", flush=True)
        # Model calls are slow and mostly waiting on the network, so threads
        # rather than the default 4 keeps a queue from forming.
        serve(app, host=host, port=port, threads=8)
