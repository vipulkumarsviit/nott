local edge_computing = {}

--- computing unit ---
---    cu = {}
---    cu["id"] = "coding id"
---    cu["phase"] = "phase"
---    cu["code"] = function_code
--- computing unit ---

edge_computing.cus = {}
edge_computing.ready = false
edge_computing.interval = 20 -- seconds
edge_computing.phases = {
  "init", "init_worker", "ssl_cert", "ssl_session_fetch", "ssl_session_store", "set",
  "rewrite", "balancer", "access", "content", "header_filter", "body_filter", "log",
  "timer"
}

-- https://stackoverflow.com/questions/1426954/split-string-in-lua
edge_computing.split = function(input_string, separator)
  if separator == nil then
    separator = "%s"
  end
  local t={}
  for str in string.gmatch(input_string, "([^"..separator.."]+)") do
    table.insert(t, str)
  end
  return t
end

-- lua phases
-- https://github.com/openresty/lua-nginx-module#ngxget_phase
edge_computing.phase = function()
  return ngx.get_phase()
end

edge_computing.log = function(msg)
  ngx.log(ngx.ERR, " :: edge_computing :: [" .. ngx.worker.id() .. "] "  .. msg)
end

edge_computing.initialize_cus = function()
  edge_computing.cus = {}
  for _, phase in ipairs(edge_computing.phases) do
    edge_computing.cus[phase] = {}
  end
end

-- receives an instance of redis_client
edge_computing.start = function(redis_client, interval)
  -- run once per worker
  if edge_computing.ready then
    return true, nil
  end

  -- we can't run earlier like init_worker due to
  -- resty-lock (used by redis cluster) restrictions around the phases
  if edge_computing.phase() ~= "rewrite" then
    return nil, "expect lua phase to be rewrite* not " .. edge_computing.phase()
  end

  if not redis_client then
    return nil, "you must specify the redis_client"
  end

  if interval then
    edge_computing.interval = interval
  end

  edge_computing.redis_client = redis_client
  edge_computing.initialize_cus()
  ngx.timer.every(edge_computing.interval, edge_computing.update)
  edge_computing.ready = true
  -- forcing the first query
  -- otherwise we'd pass the first request
  edge_computing.update()

  return true, nil
end

edge_computing.update = function()
  if not edge_computing.ready then
    edge_computing.log("update not ready")
    return false
  end

  local raw_coding_units, err = edge_computing.raw_coding_units()
  if err then
    edge_computing.log(err)
    return false
  end

  local status, err = edge_computing.parse(raw_coding_units)
  if #err ~= 0 then
    for _, e in ipairs(err) do
      edge_computing.log(e)
    end
    return true
  end

  return true, nil
end

-- returns status and computing units runtime errors
-- it can be true and still have some runtime errors
edge_computing.execute = function()
  if not edge_computing.ready then
    return nil, {"not ready"}
  end

  local phase = edge_computing.phase()
  local runtime_errors = {}

  for _, cu in ipairs(edge_computing.cus[phase]) do
    -- should we call it passing, redis?
    local status, ret = pcall(cu["code"], {redis_client=edge_computing.redis_client})

    if not status then
      table.insert(runtime_errors, "execution of cu id=" .. cu["id"] .. ", failed due err=" .. ret)
    end
  end

  return true, runtime_errors
end

edge_computing.raw_coding_units = function()
  local resp, err = edge_computing.redis_client:smembers("coding_units")
  if err then
    return nil, err
  end

  local raw_coding_units = {}
  for _, coding_unit_key in ipairs(resp) do
    local resp, err = edge_computing.redis_client:get(coding_unit_key)
    if err then
      return nil, err
    end

    local raw_coding_unit = {}
    raw_coding_unit["id"] = coding_unit_key
    raw_coding_unit["value"] = resp
    table.insert(raw_coding_units, raw_coding_unit)
  end

  return raw_coding_units, nil
end

edge_computing.loadstring = function(str_code)
  -- API wrapper
  local api_fun, err = loadstring("return function (edge_computing) " .. str_code .. " end")
  if api_fun then
    return api_fun()
  else
    return api_fun, err
  end
end

edge_computing.parse = function(raw_coding_units)
  edge_computing.initialize_cus()
  local parse_errors = {}
  for _, raw_coding_unit in ipairs(raw_coding_units) do
    local parts = edge_computing.split(raw_coding_unit["value"], "||")

    local phase = parts[1]
    local raw_code = parts[2]
    local function_code, err = edge_computing.loadstring(raw_code)
    if err ~= nil then
      local parse_error = "the computing unit id=" .. raw_coding_unit["id"] .. " failed to parse due err=" .. err
      table.insert(parse_errors, parse_error)
      goto continue
    end

    local cu = {}
    cu["id"] = raw_coding_unit["id"]
    cu["phase"] = parts[1]
    cu["code"] = function_code

    table.insert(edge_computing.cus[cu["phase"]], cu)
    ::continue::
  end
  return true, parse_errors
end

return edge_computing
