-- =====================================================================
-- FullSkinUnlock v2  全皮肤全物品解锁（基于官方 v4.6.0 源码精确签名实现）
--
-- 原理：向官方衣柜仓库实体（logic_wardrobe_data_center 单例 DataEntity）
--       注入虚拟物品。虚拟 insID = 990000000000 + resID
--       （官方 insID = (时间戳<<32)|序号 ≈1.7e18，绝不冲突）
--       expireTS = 0 即永久（与官方永久物品一致）。
--
-- 注入时机：模块加载后立即尝试 + 定时重试（兼容注入器在任意时机加载本文件），
--           并 Hook WardrobeDataEntity:InitData 捕获官方重建。
--
-- 穿脱/枪皮/表情：虚拟物品全部走官方本地回包（on_puton_rsp 等），
--                 复用官方全套穿戴流程，不请求服务器。
--
-- 诊断：日志写 /sdcard/fullskin_dbg.txt，关键事件弹 ShowNotice。
-- =====================================================================
if _G.FullSkinUnlockLoaded then return end
_G.FullSkinUnlockLoaded = true

local M = {}
local VIRTUAL_INS_BASE = 990000000000

-- ---------------- 诊断 ----------------
local DBGFILE = nil
for _, p in ipairs({"/sdcard/fullskin_dbg.txt", "/storage/emulated/0/fullskin_dbg.txt"}) do
  local f = io.open(p, "a")
  if f then DBGFILE = f break end
end
local function log(msg)
  local line = tostring(os and os.date and os.date("%X") or "") .. " " .. tostring(msg)
  if DBGFILE then DBGFILE:write(line .. "\n") DBGFILE:flush() end
  pcall(function() if print then print("[FullSkin] " .. tostring(msg)) end end)
end
local function notify(msg)
  pcall(function() if ShowNotice then ShowNotice("[FullSkin] " .. tostring(msg), false, 5) end end)
end
log("==== 模块加载 ====")

-- ---------------- 1) 目录 ----------------
local catalog = nil
local function addID(set, id)
  id = tonumber(id)
  if id and id > 0 then set[id] = true end
end
local function buildCatalog()
  if catalog then return catalog end
  local set = {}
  local ok, err = pcall(function()
    for k, row in pairs(CDataTable.GetTable("Item") or {}) do
      local id = tonumber(k) or tonumber(row and (row.ID or row.Id))
      if id and row and (tonumber(row.WardrobeMainTab or row.wardrobeMainTab) or 0) > 0 then
        addID(set, id)
      end
    end
    local function scanField(tbl, field)
      for _, row in pairs(CDataTable.GetTable(tbl) or {}) do
        addID(set, field and row[field] or nil)
      end
    end
    scanField("HallThemeItem", "ItemID")
    scanField("GarageThemeID", "ItemID")
    scanField("PetTable")
    scanField("PetDressTable")
    scanField("WeaponSkinMapping")
    scanField("VehiclePlaneSkinMapping")
    scanField("BetterVehicleEffect")
    scanField("ItemUpgradeConfig", "ItemID")
  end)
  if not ok then log("目录构建失败: " .. tostring(err)) return nil end
  -- 升级组去重：同组只保留最高级（低级版本不注入，避免衣柜里一堆同名低级装）
  local function buildLevelExclude()
    local exclude = {}
    local function scan(tbl, groupKey)
      local groups = {}
      for _, row in pairs(CDataTable.GetTable(tbl) or {}) do
        local g = tonumber(row[groupKey])
        local id = tonumber(row.ItemID)
        local lv = tonumber(row.Star or row.star or row.Level or row.level)
        if g and id and lv then
          groups[g] = groups[g] or { max = 0 }
          if lv > groups[g].max then groups[g].max = lv end
          groups[g][lv] = id
        end
      end
      for _, t in pairs(groups) do
        for lv, id in pairs(t) do
          if type(lv) == "number" and lv ~= t.max then exclude[id] = true end
        end
      end
    end
    pcall(function() scan("ItemUpgradeConfig", "GroupID") end)       -- 升级枪/圣装等
    pcall(function() scan("GoldenSuitUpgradeCfg", "Period") end)     -- 黄金圣装
    pcall(function() scan("GoldenSuitUpgradeCfgKJ", "Period") end)
    pcall(function() scan("GoldenSuitUpgradeCfgIN", "Period") end)
    return exclude
  end
  local ex = buildLevelExclude()
  local exn = 0
  for id in pairs(ex) do
    if set[id] then set[id] = nil exn = exn + 1 end
  end
  catalog = set
  local n = 0 for _ in pairs(set) do n = n + 1 end
  log(string.format("目录构建完成: %d 个物品 ID（已过滤 %d 个低级重复）", n, exn))
  return catalog
end

-- ---------------- 2) 虚拟物品工厂 ----------------
-- 注意：官方 AddData 读的是 snake_case 字段（instid/res_id/isnew/expire_ts/color/pattern...）
local function makeItem(resID)
  return {
    instid = VIRTUAL_INS_BASE + resID,
    res_id = resID,
    count = 1,
    lock_cnt = 0,
    isnew = 0,
    valid_hours = 0,
    expire_ts = 0,
    color = 0,
    pattern = 0,
    notified_3day = false,
    notified_1week = false,
  }
end
M.isVirtual = function(insID)
  insID = tonumber(insID)
  return insID and insID >= VIRTUAL_INS_BASE
end
M.toResID = function(insID) return tonumber(insID) - VIRTUAL_INS_BASE end

-- ---------------- 3) 注入 ----------------
local lastInjectCount = 0
function M.inject(entity)
  if not entity then return false end
  local cat = buildCatalog()
  if not cat then return false end
  if entity.__fullskin_injected then
    -- 已注过；若目录变大可增量补
  end
  local n, skipped = 0, 0
  local ok, err = pcall(function()
    for resID in pairs(cat) do
      local exists = entity:GetDataByResID(resID)
      if exists then
        skipped = skipped + 1
      else
        entity:AddData(makeItem(resID))
        n = n + 1
      end
    end
  end)
  if not ok then
    log("注入失败: " .. tostring(err))
    return false
  end
  entity.__fullskin_injected = true
  lastInjectCount = n
  log(string.format("注入完成: 新增 %d 件，跳过已有 %d 件", n, skipped))
  if n > 0 then
    notify("解锁生效：注入 " .. n .. " 件物品")
    pcall(function()
      if EventSystem and EVENTTYPE_WARDROBE then
        if EVENTID_WARDROBE_UPDATE_ITEM_LIST then
          EventSystem:postEvent(EVENTTYPE_WARDROBE, EVENTID_WARDROBE_UPDATE_ITEM_LIST)
        end
        if EVENTID_WARDROBE_UPDATE_AVATAR_LIST then
          EventSystem:postEvent(EVENTTYPE_WARDROBE, EVENTID_WARDROBE_UPDATE_AVATAR_LIST)
        end
        if EVENTID_WARDROBE_UPDATE_GUN_LIST then
          EventSystem:postEvent(EVENTTYPE_WARDROBE, EVENTID_WARDROBE_UPDATE_GUN_LIST, -1)
        end
      end
    end)
  end
  return true
end

-- 获取当前实体（官方单例；nil 源默认为 Wardrobe）
function M.getEntity()
  local ok, e = pcall(function()
    local dc = require("client.slua.logic.wardrobe.logic_wardrobe_data_center")
    return dc.GetWardrobeData and dc.GetWardrobeData()
  end)
  if ok and e and type(e) == "table" then return e end
  return nil
end

-- 注入尝试（立即 + 多次重试，覆盖晚加载场景）
local function tryInject(tag)
  local e = M.getEntity()
  if e then
    log("尝试注入（" .. tag .. "）: 实体存在=" .. tostring(e ~= nil))
    if M.inject(e) then return true end
  else
    log("尝试注入（" .. tag .. "）: 实体尚未创建")
  end
  return false
end

-- Hook InitData（官方仓库数据到达/重建时）
pcall(function()
  local WDE = require("client.slua.logic.wardrobe.WardrobeDataEntity")
  local origInit = WDE.InitData
  function WDE:InitData(pkg)
    origInit(self, pkg)
    pcall(function() M.inject(self) end)
  end
  log("InitData Hook 完成")
end)

-- 事件兜底 + 定时重试
pcall(function()
  if EventSystem and EventSystem.registEvent and EVENTTYPE_DATA_MGR and EVENTID_DATAMGR_HALL_DEPOT_CHANGE then
    EventSystem:registEvent(EVENTTYPE_DATA_MGR, EVENTID_DATAMGR_HALL_DEPOT_CHANGE, function()
      pcall(function()
        local e = M.getEntity()
        if e then M.inject(e) end
      end)
    end)
  end
end)
pcall(function()
  local ticker = require("common.time_ticker")
  if not (ticker and ticker.AddTimerOnce) then return end
  for _, d in ipairs({0.5, 2, 5, 10, 20, 40}) do
    ticker.AddTimerOnce(d, function() tryInject("t+" .. d .. "s") end)
  end
end)
tryInject("立即")

-- ---------------- 4) 穿脱/表情 Hook ----------------
function M.findOldWear(resID)
  local ok, ret = pcall(function()
    local cfg = CDataTable.GetTableData("Item", resID)
    if not cfg then return nil end
    local wd = require("client.slua.logic.wardrobe.wardrobe_data")
    local AvatarData = require("client.logic.data.AvatarData")
    for _, ins in pairs(AvatarData.GetRoleWear() or {}) do
      local it = wd.GetHallDepotItemDataByInsID and wd:GetHallDepotItemDataByInsID(ins)
      if it and tonumber(it.itemSubType) == tonumber(cfg.ItemSubType) and tonumber(ins) ~= (VIRTUAL_INS_BASE + resID) then
        return { res_id = tonumber(it.resID or it.res_id), instid = tonumber(ins), expire_ts = 0, count = 1 }
      end
    end
    return nil
  end)
  return ok and ret or nil
end

pcall(function()
  local WL = require("client.slua.logic.wardrobe.logic_wardrobe_new")
  local origPutOn = WL.wardrobe_puton_req
  function WL:wardrobe_puton_req(insID, extra)
    insID = tonumber(insID)
    if M.isVirtual(insID) then
      local resID = M.toResID(insID)
      local item = { res_id = resID, instid = insID, expire_ts = 0, count = 1, color_id = 0, pattern_id = 0 }
      pcall(function() self:on_puton_rsp(NetErrorCode_NONE, item, M.findOldWear(resID), 1, extra) end)
      log("本地穿上虚拟物品 resID=" .. resID)
      return
    end
    return origPutOn(self, insID, extra)
  end
  local origPutDown = WL.wardrobe_put_down_req
  function WL:wardrobe_put_down_req(insID)
    insID = tonumber(insID)
    if M.isVirtual(insID) then
      pcall(function()
        self:on_putdown_rsp(NetErrorCode_NONE, { res_id = M.toResID(insID), instid = insID, expire_ts = 0, count = 1 })
      end)
      return
    end
    return origPutDown(self, insID)
  end
  local origMotion = WL.EquipMotion
  function WL:EquipMotion(motionID, dst_slot)
    if M.isVirtual(motionID) then
      pcall(function()
        DataMgr.MotionSlotList = DataMgr.MotionSlotList or {}
        while #DataMgr.MotionSlotList < dst_slot do table.insert(DataMgr.MotionSlotList, 0) end
        DataMgr.MotionSlotList[dst_slot] = tonumber(motionID)
        if EventSystem and EVENTTYPE_MOTION and EVENTID_MOTION_UPDATE_SLOT_LIST then
          EventSystem:postEvent(EVENTTYPE_MOTION, EVENTID_MOTION_UPDATE_SLOT_LIST)
        end
      end)
      return
    end
    return origMotion(self, motionID, dst_slot)
  end
  log("穿脱/表情 Hook 完成")
end)

-- ---------------- 5) 军械库枪皮 ----------------
pcall(function()
  local Arm = require("client.logic.armory.logic_armory")
  Arm.rsp_list = Arm.rsp_list or { skin_list = {}, install_list = {} }
  Arm.rsp_list.skin_list = Arm.rsp_list.skin_list or {}
  local cat = buildCatalog()
  if cat then
    local n = 0
    for resID in pairs(cat) do
      local row = CDataTable.GetTableData("WeaponSkinMapping", resID)
      if row then
        local wid = tonumber(row.WeaponID)
        if wid then
          Arm.rsp_list.skin_list[wid] = Arm.rsp_list.skin_list[wid] or {}
          if not Arm.rsp_list.skin_list[wid][resID] then
            Arm.rsp_list.skin_list[wid][resID] = { is_open = 1 }
            n = n + 1
          end
        end
      end
    end
    log("军械库皮肤列表补录: " .. n .. " 条")
  end
  local origInstall = Arm.install_weapon_skin
  function Arm:install_weapon_skin(weaponID, skinInsID)
    skinInsID = tonumber(skinInsID)
    if M.isVirtual(skinInsID) then
      pcall(function() self:install_weapon_skin_rsp(NetErrorCode_NONE, weaponID, skinInsID) end)
      pcall(function()
        self.rsp_list.install_list = self.rsp_list.install_list or {}
        self.rsp_list.install_list[weaponID] = { skin_id = skinInsID }
      end)
      -- 刷新大厅持枪形象（部分版本 rsp 不自动刷新）
      pcall(function()
        local gun = require("client.slua.logic.wardrobe.logic_wardrobe_gun")
        if gun and gun.UpdateCurrentGunAvatar then
          gun:UpdateCurrentGunAvatar(weaponID, skinInsID)
        end
      end)
      log("本地安装枪皮 weapon=" .. tostring(weaponID) .. " ins=" .. skinInsID)
      return
    end
    return origInstall(self, weaponID, skinInsID)
  end
  -- 卸载 Hook：虚拟枪皮本地回包（官方 rsp 会清 install_list 并刷新显示）
  local origUninstall = Arm.uninstall_weapon_skin
  function Arm:uninstall_weapon_skin(weaponID)
    weaponID = tonumber(weaponID)
    local installed = self.rsp_list and self.rsp_list.install_list and self.rsp_list.install_list[weaponID]
    local skinIns = installed and tonumber(installed.skin_id) or 0
    if M.isVirtual(skinIns) then
      pcall(function() self:uninstall_weapon_skin_rsp(NetErrorCode_NONE, weaponID) end)
      pcall(function()
        self.rsp_list.install_list[weaponID].skin_id = 0
      end)
      pcall(function()
        local gun = require("client.slua.logic.wardrobe.logic_wardrobe_gun")
        if gun and gun.UpdateCurrentGunAvatar then
          gun:UpdateCurrentGunAvatar(weaponID, 0)
        end
      end)
      log("本地卸载枪皮 weapon=" .. tostring(weaponID))
      return
    end
    return origUninstall(self, weaponID)
  end
  log("军械库 Hook 完成（安装/卸载）")
end)

log("模块顶层执行完毕")
return M