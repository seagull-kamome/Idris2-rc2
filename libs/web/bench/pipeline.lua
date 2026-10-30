-- 16 requests in every write
local batch

init = function(args)
  local requests = {}
  for i = 1, 16 do
    requests[i] = wrk.format("GET", "/hello")
  end
  batch = table.concat(requests)
end

request = function() return batch end
