package.path = package.path .. ";lua/?.lua"
local acl = require "lua.acl"
local curiefense = require "curiefense"
local session = require("session")
local sfmt = string.format
local cjson = require "cjson"
local json_safe = require "cjson.safe"
local json_decode = json_safe.decode
local tagprofiler = require "lua.tagprofiler"

ACLNoMatch   = -1
ACLForceDeny = 0
ACLBypass    = 1
ACLAllowBot  = 2
ACLDenyBot   = 3
ACLAllow     = 4
ACLDeny      = 5

function read_file(path)
    local fh = io.open(path, "r")
    if fh ~= nil then
        local data = fh:read("*all")
        fh:close()
        if data then
            return data
        end
    end
end
function load_json_file(path)
    local data = read_file(path)
    if data then
        return json_decode(data)
    end
end

session.global_init(nil)
local _, err = curiefense.init_config()
if err then
    for _, r in ipairs(err) do
        error(sfmt("curiefense.init_config failed %s", r))
    end
end

local FakeHandle = {}
function FakeHandle:logDebug(content)
  -- ignore debug
end

function identical_tags_resolved(stage, expected, actual)
  -- checks that all expected entries are in
  local identical = true

  for ek, _ in pairs(expected) do
    if expected[ek] ~= actual[ek] then
      print(sfmt("%s - missing tag %s", stage, ek, expected[ek], actual[ek]))
      identical = false
    end
  end

  for ek, _ in pairs(actual) do
    if expected[ek] ~= actual[ek] then
      print(sfmt("%s - extra tag %s", stage, ek, expected[ek], actual[ek]))
      identical = false
    end
  end

  return identical
end

function identical_tags(stage, request_map, session_uuid)
  local expected = request_map.attrs.tags
  local srm, err = curiefense.session_serialize_request_map(session_uuid)
  if err then
    error("could not serialize request map: " .. err)
  end
  local actual = cjson.decode(srm)["attrs"]["tags"]

  return identical_tags_resolved(stage, expected, actual)
end

function test_request(request_path)
  local raw_request_map = load_json_file(request_path)
  local request_map = raw_request_map
  request_map.handle = FakeHandle

  local url = request_map.attrs.path
  local host = request_map.headers.host or request_map.attrs.authority

  local encoded = session.encode_request_map(request_map)
  session_uuid, err = curiefense.session_init(encoded)
  if err then
    error("session_init failed: " .. err)
  end

  local urlmap_entry, url_map = session.match_urlmap(host, url, request_map)

  local acl_active        = urlmap_entry["acl_active"]
  local waf_active        = urlmap_entry["waf_active"]
  local acl_profile_id    = urlmap_entry["acl_profile"]
  local waf_profile_id    = urlmap_entry["waf_profile"]
  local acl_profile       = session.get_acl_profile(acl_profile_id)
  local waf_profile       = session.get_waf_profile(waf_profile_id)

  json_urlmap, err = curiefense.session_match_urlmap(session_uuid)
  if err then
    error("session_match_urlmap failed: " .. err)
  end
  local rust_urlmap = cjson.decode(json_urlmap)

  for _, k in ipairs({"acl_profile", "waf_profile", "acl_active", "waf_active"}) do
    if rust_urlmap[k] ~= urlmap_entry[k] then
      error(sfmt("urlmap field %s error, expected=%s actual=%s", k, urlmap_entry[k], rust_urlmap[k]))
    end
  end

  session.map_tags(request_map,
      sfmt('urlmap:%s', url_map.name),
      sfmt('urlmap-entry:%s', urlmap_entry.name),
      sfmt("aclid:%s", acl_profile_id),
      sfmt("aclname:%s", acl_profile.name),
      sfmt("wafid:%s", waf_profile_id),
      sfmt("wafname:%s", waf_profile.name)
  )

  local _, err = curiefense.session_tag_request(session_uuid)
  if err then
      error("curiefense.session_tag_request failed " .. err)
  end

  tagprofiler.tag_lists(request_map)

  if not identical_tags("match_urlmap", request_map, session_uuid) then
    error("failed at stage match_urlmap")
  end

  -- TODO: check redis related stuff, flow control and rate limit

  local acl_code, acl_result = acl.check(acl_profile, request_map, acl_active)
  local acl_bot_code, acl_bot_result = acl.check_bot(acl_profile, request_map, acl_active)

  local r_acl_code = nil
  local r_acl_bot_code = nil

  local jrust_acl, err = curiefense.session_acl_check(session_uuid)
  if err then
      error("curiefense.session_acl_check failed " .. err)
  end
  local rust_acl = cjson.decode(jrust_acl)
  if rust_acl["Match"] then
    bot = rust_acl["Match"]["bot"]
    human = rust_acl["Match"]["human"]
    if bot ~= cjson.null then
      if bot["allowed"] then
        r_acl_bot_code = ACLAllowBot
      else
        r_acl_bot_code = ACLDenyBot
      end
    end
    if human ~= cjson.null then
      if human["allowed"] then
        r_acl_code = ACLAllow
      else
        r_acl_code = ACLDeny
      end
    end
  else
    if rust_acl["Bypass"]["allowed"] then
      r_acl_code = ACLBypass
    else
      r_acl_code = ACLForceDeny
    end
  end

  if r_acl_code ~= acl_code then
    error(sfmt("acl_code differs, expected %s, actual %s", acl_code, r_acl_code))
  end
  if r_acl_bot_code ~= acl_bot_code then
    error(sfmt("acl_bot_code differs, expected %s, actual %s", acl_bot_code, r_acl_bot_code))
  end
end

test_request("luatests/requests/r1.json")