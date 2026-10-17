-- 主通道用完整音节造句并补全尾音；fuzz 仅补充覆盖整个输入段的系统词条。
local M = {}

function M.init(env)
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
  env.primary = nil
  env.mixed = nil
  env.mixed_schema = nil
end

function M.func(input, seg, env)
  local primary = env.primary:query(input, seg)
  local iter, state = function() return nil end, nil
  if primary then iter, state = primary:iter() end
  local first = iter(state)
  -- 主通道首选始终保留，避免补词通道覆盖主通道造句。
  if first then yield(first) end

  -- 显式分词、拼音筛选后的字母输入和单键仍只走原通道。
  if env.mixed and #input >= 2 and input:match("^[2-9]+$") then
    local ok, mixed = pcall(function() return env.mixed:query(input, seg) end)
    if not ok then log.warning("九键补词查询失败，保留主通道: " .. tostring(mixed)) end
    if ok and mixed then
      local seen = {}
      if first then seen[first.text] = true end
      local scanned, emitted = 0, 0
      for cand in mixed:iter() do
        scanned = scanned + 1
        local kind = cand:get_genuine().type
        if (kind == "phrase" or kind == "completion") and
            cand.start == seg.start and cand._end == seg._end and
            not seen[cand.text] then
          seen[cand.text] = true
          yield(cand)
          emitted = emitted + 1
        end
        -- 只补首屏附近的词条；不遍历整个 fuzz 候选池。
        if emitted >= 8 or scanned >= 64 then break end
      end
    end
  end

  for cand in iter, state do yield(cand) end
end

return M
