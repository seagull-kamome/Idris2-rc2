# Stand-in for an OpenAI-compatible API and an OAuth 2.0 token endpoint,
# so webapi's tests need no outbound network. Bound to 127.0.0.1 on a
# free port, which it prints as "port N" (verify.sh reads it).
import hashlib, base64, json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

CHALLENGES = {}


def s256(v):
    return base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b"=").decode()


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # The test plays the browser: it registers the challenge from the
        # authorization URL here, as the real server would remember it.
        if self.path.startswith("/auth?"):
            q = parse_qs(self.path.split("?", 1)[1])
            CHALLENGES["good-code"] = q["code_challenge"][0]
            self.reply(200, {})
        else:
            self.reply(404, {})

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        if self.path == "/v1/chat/completions":
            if self.headers.get("Authorization") != "Bearer test-key":
                return self.reply(401, {"error": {"message": "invalid api key", "type": "auth"}})
            req = json.loads(data)
            text = "echo: %s (model %s, max_tokens %s)" % (
                req["messages"][-1]["content"], req["model"], req.get("max_tokens"))
            return self.reply(200, {"model": req["model"], "choices": [
                {"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}]})
        if self.path == "/token":
            f = {k: v[0] for k, v in parse_qs(data).items()}
            if f.get("client_id") != "cid" or f.get("client_secret") != "sec":
                return self.reply(401, {"error": "invalid_client"})
            if f.get("grant_type") == "authorization_code":
                ok = (f.get("code") in CHALLENGES
                      and s256(f.get("code_verifier", "")) == CHALLENGES[f["code"]])
                if not ok:
                    return self.reply(400, {"error": "invalid_grant", "error_description": "bad code or verifier"})
                return self.reply(200, {"access_token": "at-1", "refresh_token": "rt-1", "expires_in": 3600})
            if f.get("grant_type") == "refresh_token" and f.get("refresh_token") == "rt-1":
                return self.reply(200, {"access_token": "at-2", "expires_in": 3600})
            return self.reply(400, {"error": "invalid_grant", "error_description": "bad refresh token"})
        self.reply(404, {})

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
print("port", server.server_address[1], flush=True)
server.serve_forever()
