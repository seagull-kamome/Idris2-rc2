wrk.method = "POST"
wrk.path = "/echo"
wrk.body = string.rep("x", 65536)
wrk.headers["Content-Type"] = "application/octet-stream"
