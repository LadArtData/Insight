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


# Answer review. A regex can tell that "asdfgh" is not an answer; it cannot
# tell that "Who cares!" is not an answer to a question about Tax IDs. That
# judgement is what the model is for.
#
# Three verdicts, because two would force every borderline answer into either
# "block a real person" or "accept anything":
#
#   ok        answers the question -- save it
#   unclear   on topic but does not actually answer, or is too thin to be
#             usable -- warn, let the person decide
#   nonsense  not an answer at all -- refuse it
#
# The model is told to be conservative: a terse answer from someone who knows
# the subject is still an answer, and refusing those is worse than accepting a
# weak one, because the person then has no way forward except padding.
REVIEW_FRAMING = """You are reviewing answers captured in an Oracle Fusion Financials \
discovery questionnaire, before they are saved. You will be given one question and the answer \
someone typed. Decide whether the answer is usable.

Verdicts:
- "ok": it answers the question, even if brief or informal. A short answer from someone who \
knows the subject is fine. So is "we don't do that", "not applicable", or naming a system or a \
number without elaboration.
- "unclear": on topic but does not actually answer what was asked, or is too vague to act on \
(for example "some", "the usual", "TBD", or answering a different question).
- "nonsense": not an answer at all -- keyboard mashing, random characters, a joke, or a refusal \
to engage such as "who cares".

Be conservative. When in doubt between "ok" and "unclear", choose "ok". Only use "nonsense" \
when the text could not be a good-faith answer from anyone.

"reason" is shown to the person, so write it as one short, courteous sentence telling them what \
is missing. Leave it empty when the verdict is "ok".

Respond with ONLY a JSON object, no other text, in exactly this shape:
{"verdict": "ok|unclear|nonsense", "reason": "..."}"""


def build_review_prompt(question_text, answer_type, answer):
    return (
        f"{REVIEW_FRAMING}\n\n"
        f'Question ({answer_type} type): "{question_text}"\n\n'
        f'Answer typed: "{answer}"'
    )


def parse_review_response(raw_text):
    """
    Parses the review verdict. Anything unparseable is treated as "ok".

    That direction is deliberate. A malformed model reply is a fault in this
    service, and refusing someone's work because of one would be the worse
    failure -- they would have no way to continue and no idea why. The local
    check in the front end still applies, so obvious garbage is still caught.
    """
    try:
        parsed = json.loads(raw_text.strip())
        verdict = parsed.get("verdict")
        if verdict not in ("ok", "unclear", "nonsense"):
            raise ValueError("unrecognised verdict")
        reason = parsed.get("reason")
        return {"verdict": verdict, "reason": reason if isinstance(reason, str) else ""}
    except (json.JSONDecodeError, ValueError, AttributeError):
        return {"verdict": "ok", "reason": ""}


# Coaching, not answering. The consultant is being helped to run an intake,
# not to invent the client's answers -- a model guessing that a county
# probably has three funds is worse than a blank, because a blank is
# visibly missing and a guess is not.
#
# The panel's static guidance is passed in when there is any, so the reply
# builds on it rather than contradicting it.
EXPLAIN_FRAMING = """You are helping a consultant who is running an Oracle Fusion Financials \
discovery interview, possibly for the first time. They will show you one question from the \
questionnaire and ask you something about it.

Explain, in plain language, what the question is really asking and what a good answer looks \
like. You may explain Oracle Fusion concepts, why a setup matters, and what typically goes \
wrong when it is decided badly.

Never invent the client's answer. You do not know this client. If asked what the answer should \
be, explain what it depends on and what to ask them instead. A guess that reads as fact is \
worse than a blank, because a blank is visibly missing.

Keep it under 150 words, and write as one professional to another -- no headings, no bullet \
lists, no restating the question back.

Respond with ONLY a JSON object, no other text, in exactly this shape:
{"answer": "..."}"""


def build_explain_prompt(question_text, eyebrow, guidance, consultant_question):
    lines = [EXPLAIN_FRAMING, "", f'Questionnaire question: "{eyebrow} — {question_text}"']
    if guidance:
        # Only the fields the panel actually shows, so the model cannot be
        # confused by anything editorial in the guidance file.
        known = {k: guidance.get(k) for k in ("feeds", "why", "good", "followUp", "example")
                 if guidance.get(k)}
        if known:
            lines += ["", "Reference material already shown to the consultant:",
                      json.dumps(known, indent=1)]
    lines += ["", f'The consultant asks: "{consultant_question}"']
    return "\n".join(lines)


def parse_explain_response(raw_text):
    """Falls back to the raw text when the model does not return JSON.

    Unlike the gap chat, nothing here is stored or acted on -- it is read by
    a person and then discarded. A prose reply is still useful to them, so
    showing it beats discarding it over a formatting mistake.
    """
    try:
        parsed = json.loads(raw_text.strip())
        answer = parsed.get("answer")
        if isinstance(answer, str) and answer.strip():
            return {"answer": answer}
    except (json.JSONDecodeError, ValueError, AttributeError):
        pass
    text = (raw_text or "").strip()
    return {"answer": text} if text else {"answer": "No explanation came back. Try rephrasing."}


def call_explain(question_text, eyebrow, guidance, consultant_question):
    return invoke_model(
        build_explain_prompt(question_text, eyebrow, guidance, consultant_question))


# Reading a client's existing spreadsheet.
#
# For a client already being served there is no discovery interview to run --
# the engagement happened years ago and a hand-filled workbook is the only
# record of it. So this asks the model to answer the questionnaire FROM that
# workbook, and to say which cell each answer came from.
#
# The citation requirement is not politeness. Every answer is checked against
# the cell it names before anyone sees it, which turns "the AI read it" into
# something auditable. An import nobody can audit produces a client file full
# of plausible unverified values, which is worse than an empty one, because an
# empty one is visibly empty.
IMPORT_FRAMING = """You are reading a client's completed Oracle Fusion configuration \
spreadsheet in order to answer a discovery questionnaire about that client. The spreadsheet \
is given to you as a list of cells, each with its address.

For each question you can answer FROM THE SPREADSHEET, return the answer and the addresses of \
the cells it came from.

Rules, in order of importance:

1. Never answer from general knowledge. If the spreadsheet does not say, omit the question \
entirely. A missing answer is a true statement about what was recorded; an invented one is not, \
and it is far more expensive because nobody can tell it apart from a real one.
2. Every answer must cite at least one cell address, copied exactly as given. Answers without \
citations are discarded before anyone sees them, so an uncited answer is wasted work.
3. An empty section is itself an answer. If a sheet exists but has no rows, say so plainly -- \
"none defined" -- and cite the sheet's header cell. That is a finding, not a gap.
4. Keep each answer under 240 characters and factual. No hedging, no recommendations.
5. If the spreadsheet contradicts itself, still answer, and describe the contradiction in the \
answer rather than choosing a side.

Respond with ONLY a JSON object, no other text, in exactly this shape:
{"answers": [{"questionId": "GL-004", "answer": "...", "evidence": ["Sheet!A1", "Sheet!B2"]}]}"""


def build_import_prompt(questions, digest_text):
    lines = [IMPORT_FRAMING, "", "QUESTIONS:"]
    for q in questions:
        lines.append('%s (%s): %s' % (q.get("id"), q.get("type", "text"), q.get("text", "")))
    lines += ["", "SPREADSHEET:", digest_text]
    return "\n".join(lines)


def parse_import_response(raw_text):
    """
    Parses proposed answers. Anything malformed yields none at all.

    Deliberately all-or-nothing: a half-parsed import is indistinguishable
    from a complete one to whoever is looking at the review screen, and
    "the model proposed 4 answers" when it proposed 40 is a silent loss.
    """
    try:
        parsed = json.loads(raw_text.strip())
        proposals = parsed.get("answers")
        if not isinstance(proposals, list):
            raise ValueError("answers must be a list")
    except (json.JSONDecodeError, ValueError, AttributeError):
        return []

    out = []
    for p in proposals:
        if not isinstance(p, dict):
            continue
        qid = p.get("questionId")
        answer = p.get("answer")
        evidence = p.get("evidence")
        if not isinstance(qid, str) or not isinstance(answer, str) or not answer.strip():
            continue
        if not isinstance(evidence, list):
            evidence = []
        out.append({
            "questionId": qid.strip(),
            "answer": answer.strip(),
            "evidence": [str(e).strip() for e in evidence if str(e).strip()],
        })
    return out


def call_import(questions, digest_text):
    return invoke_model(build_import_prompt(questions, digest_text))


def call_llm(gap_context, user_message):
    """
    The one function that actually talks to OCI. Kept separate from the
    Flask route (below) so tests can monkeypatch just this function and
    exercise the route's request validation / response handling without
    ever constructing a real OCI client.
    """
    return invoke_model(build_prompt(gap_context, user_message))


def call_review(question_text, answer_type, answer):
    """Asks the model whether an answer is usable. Same plumbing as call_llm."""
    return invoke_model(build_review_prompt(question_text, answer_type, answer))


def invoke_model(prompt):
    """The single place a request is actually sent to OCI."""
    import oci  # local import -- see get_oci_client()

    client = get_oci_client()

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


@app.route("/review", methods=["POST"])
def review():
    body = request.get_json(silent=True)
    if not body:
        return jsonify({"error": "Request body must be JSON"}), 400

    question_text = body.get("questionText")
    answer = body.get("answer")
    answer_type = body.get("answerType") or "text"
    if not question_text or not answer:
        return jsonify({"error": "questionText and answer are required"}), 400
    if len(answer) > 2000 or len(question_text) > 1000:
        return jsonify({"error": "questionText or answer is too long"}), 400

    try:
        raw_text = call_review(question_text, answer_type, answer)
    except Exception as exc:  # noqa: BLE001 -- any OCI/network failure
        # 502 rather than a verdict. The front end treats an unreachable
        # reviewer as "no opinion" and falls back to its own check, so
        # inventing "ok" here would be indistinguishable from the model
        # having actually approved the answer.
        app.logger.error("OCI review call failed: %s", exc)
        return jsonify({"error": "The reviewer is temporarily unavailable."}), 502

    return jsonify(parse_review_response(raw_text))


@app.route("/explain", methods=["POST"])
def explain():
    body = request.get_json(silent=True)
    if not body:
        return jsonify({"error": "Request body must be JSON"}), 400

    question_text = body.get("questionText")
    consultant_question = body.get("consultantQuestion")
    if not question_text or not consultant_question:
        return jsonify({"error": "questionText and consultantQuestion are required"}), 400
    if len(consultant_question) > 500 or len(question_text) > 1000:
        return jsonify({"error": "questionText or consultantQuestion is too long"}), 400

    guidance = body.get("guidance")
    if guidance is not None and not isinstance(guidance, dict):
        return jsonify({"error": "guidance must be an object"}), 400

    try:
        raw_text = call_explain(
            question_text, body.get("eyebrow") or "", guidance, consultant_question)
    except Exception as exc:  # noqa: BLE001 -- any OCI/network failure
        app.logger.error("OCI explain call failed: %s", exc)
        return jsonify({"error": "The assistant is temporarily unavailable."}), 502

    return jsonify(parse_explain_response(raw_text))


# Uploads are held in memory for the length of one request and never written
# to disk here. The container is ephemeral, a client's configuration workbook
# is some of the most sensitive material this product touches, and a temp file
# left behind by a crash is exactly the kind of leak nobody notices.
MAX_UPLOAD_BYTES = 12 * 1024 * 1024


@app.route("/import", methods=["POST"])
def import_workbook():
    """
    Reads an uploaded spreadsheet and proposes answers, each carrying the
    cells it came from and the result of checking them.

    Multipart: "file" is the workbook, "questions" is the JSON question list.
    """
    upload = request.files.get("file")
    if upload is None:
        return jsonify({"error": "a spreadsheet file is required"}), 400

    raw_questions = request.form.get("questions") or "[]"
    try:
        questions = json.loads(raw_questions)
        if not isinstance(questions, list) or not questions:
            raise ValueError("questions must be a non-empty list")
    except (json.JSONDecodeError, ValueError):
        return jsonify({"error": "questions must be a JSON list of {id, text, type}"}), 400

    blob = upload.read(MAX_UPLOAD_BYTES + 1)
    if len(blob) > MAX_UPLOAD_BYTES:
        return jsonify({"error": "that file is larger than %d MB"
                        % (MAX_UPLOAD_BYTES // (1024 * 1024))}), 413
    if not blob:
        return jsonify({"error": "that file is empty"}), 400

    import io
    import INSIGHT_workbook_reader as reader

    try:
        digest = reader.digest_workbook(io.BytesIO(blob))
    except Exception as exc:  # noqa: BLE001 -- openpyxl raises many shapes
        # Almost always "this is not a spreadsheet" or "this is .xls, not
        # .xlsx". Say which rather than 500-ing.
        app.logger.warning("could not read the uploaded workbook: %s", exc)
        return jsonify({"error": "That file could not be read as a spreadsheet. "
                                 "It needs to be .xlsx -- older .xls files must be "
                                 "re-saved first."}), 400

    if not digest["sheets"]:
        return jsonify({"error": "That spreadsheet has no populated cells."}), 400

    try:
        raw_text = call_import(questions, reader.digest_to_text(digest))
    except Exception as exc:  # noqa: BLE001 -- any OCI/network failure
        app.logger.error("OCI import call failed: %s", exc)
        return jsonify({"error": "The assistant is temporarily unavailable, so the "
                                 "spreadsheet could not be read."}), 502

    proposals = parse_import_response(raw_text)

    # Every citation is checked against the file before anyone sees the
    # answer. This is the step that separates an auditable import from a
    # confident-sounding guess.
    known = {q.get("id") for q in questions if isinstance(q, dict)}
    proposals = [p for p in proposals if p["questionId"] in known]

    # Every cited cell in one pass. Re-opening a 700 KB workbook per answer
    # would mean twenty opens for twenty answers, for no benefit.
    all_refs = sorted({ref for p in proposals for ref in p["evidence"]})
    cells = reader.read_cells(io.BytesIO(blob), all_refs) if all_refs else {}

    checked = []
    for p in proposals:
        cited = {ref: cells.get(ref, "") for ref in p["evidence"]}
        verdict = reader.verify_citations(p["answer"], cited)
        if verdict["status"] == "uncited":
            continue                      # nothing was checked, so show nothing
        checked.append({
            "questionId": p["questionId"],
            "answer": p["answer"][:240],
            "evidence": [{"ref": ref, "value": cited.get(ref, "")} for ref in p["evidence"]],
            "verification": verdict,
        })

    return jsonify({
        "proposals": checked,
        "discarded": len(proposals) - len(checked),
        "sheets_read": [s["name"] for s in digest["sheets"]],
        "truncated": digest["truncated"],
        "omitted_sheets": digest["omitted_sheets"],
    })


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
