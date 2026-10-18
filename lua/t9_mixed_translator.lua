-- 主通道用完整音节造句并补全尾音；fuzz 仅补充覆盖整个输入段的系统词条。
local M = {}

function M.init(env)
  -- 只读主用户库；不注册 memorize 回调，学习仍由原生主通道写入一次。
  env.learning = Memory(env.engine, env.engine.schema, "translator")
  env.primary = Component.ScriptTranslator(env.engine, "translator", "script_translator")
  -- 独立 schema 使用 fuzz 棱镜且禁用用户词库写入，学习只由主通道负责。
  local ok, mixed = pcall(function()
    env.mixed_schema = Schema("bim_t9_mixed")
    return Component.ScriptTranslator(env.engine, env.mixed_schema,
                                      "translator", "script_translator")
  end)
  env.mixed = ok and mixed or nil
  if not ok then log.warning("九键补词初始化失败，保留主通道: " .. tostring(mixed)) end
end

function M.fini(env)
  env.learning = nil
  env.primary = nil
  env.mixed = nil
  env.mixed_schema = nil
end

-- 用真实音节编码查同一条用户记录，避免同字异音相互抬频。
local function learned_weight(cand, memory)
  local phrase = cand:get_genuine():to_phrase()
  if not phrase then return nil end
  local code = table.concat(memory:decode(phrase.code), " ")
  if code == "" or not memory:user_lookup(code, false) then return nil end
  for entry in memory:iter_user() do
    if entry.text == cand.text and entry.commit_count > 0 and
        entry.custom_code:gsub("%s+$", "") == code then return entry.weight end
  end
  return nil
end

function M.func(input, seg, env)
  local primary = env.primary:query(input, seg)
  local iter, state = function() return nil end, nil
  if primary then iter, state = primary:iter() end
  local first = iter(state)
  -- 收集辅助系统词条，并从主用户库读取同拼音、同文字的真实学习权重。
  local supplements, learned = {}, {}
  if env.mixed and #input >= 2 and input:match("^[2-9]+$") then
    local ok, mixed = pcall(function() return env.mixed:query(input, seg) end)
    if not ok then log.warning("九键补词查询失败，保留主通道: " .. tostring(mixed)) end
    if ok and mixed then
      local seen = {}
      if first then seen[first.text] = true end
      local scanned = 0
      for cand in mixed:iter() do
        scanned = scanned + 1
        local genuine = cand:get_genuine()
        local kind = genuine.type
        if (kind == "phrase" or kind == "completion") and
            cand.start == seg.start and cand._end == seg._end and
            not seen[cand.text] then
          seen[cand.text] = true
          local weight = learned_weight(cand, env.learning)
          if weight then
            learned[#learned + 1] = {candidate = cand, weight = weight}
          else
            supplements[#supplements + 1] = cand
          end
        end
        if #supplements + #learned >= 8 or scanned >= 64 then break end
      end
    end
  end

  -- 仅真实学习过的整段词条可越过主首选；未学习时保持原有造句顺序。
  local first_weight = first and learned_weight(first, env.learning)
  if first_weight then
    table.insert(learned, 1, {candidate = first, weight = first_weight})
  end
  for index, item in ipairs(learned) do item.order = index end
  table.sort(learned, function(a, b)
    if a.weight == b.weight then return a.order < b.order end
    return a.weight > b.weight
  end)
  for _, item in ipairs(learned) do yield(item.candidate) end
  if first and not first_weight then yield(first) end
  for _, cand in ipairs(supplements) do yield(cand) end
  for cand in iter, state do yield(cand) end
end

return M
