module("luci.controller.commotion-splash.splash", package.seeall)

require "luci.sys"
require "luci.http"
require "luci.model.uci"
require "commotion_helpers"
require "nixio.fs"

function index()
	entry({"admin", "services", "splash"}, call("config_splash"), _("Captive Portal"), 90).dependent=true
	entry({"admin", "services", "splash", "splashtext" }, form("commotion-splash/splashtext"), _("Splashtext"), 10).dependent=true
	entry({"admin", "services", "splash", "submit" }, call("config_submit")).dependent=true
end

function config_splash(error_info, bad_settings)
  local splash
  
  -- get settings
  if bad_settings then
    splash = bad_settings
  else
    local current_ifaces = luci.sys.exec("grep 'GatewayInterface' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 2")
    local list = list_ifaces()
    splash = {zones={}, selected_zones={}, whitelist={}, blacklist={}, ipaddrs={}}
    
    -- get current zone(s) set in nodogsplash --> splash.zone_selected
    for zone, iface in pairs(list.zone_to_iface) do
      table.insert(splash.zones,zone)
      if current_ifaces:match(iface) then
        table.insert(splash.selected_zones, zone)
      end
    end
  
    -- get splash.leasetime
    splash.leasetime = luci.sys.exec("grep -o -E 'ClientIdleTimeout [[:digit:]]+' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 2")
  
    -- get whitelist, blacklist, ipaddrs
    local whitelist_str = luci.sys.exec("grep -o -E 'TrustedMACList .*' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 2")
    for mac in whitelist_str:gmatch("%x%x:%x%x:%x%x:%x%x:%x%x:%x%x") do
      table.insert(splash.whitelist,mac)
    end
    
    local blacklist_str = luci.sys.exec("grep -o -E 'BlockedMACList .*' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 2")
    for mac in blacklist_str:gmatch("%x%x:%x%x:%x%x:%x%x:%x%x:%x%x") do
      table.insert(splash.blacklist,mac)
    end
    
    local ipaddrs_str = luci.sys.exec("grep -o -E 'FirewallRule allow from .* #FirewallRule preauthenticated-users' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 4")
    for ipaddr in ipaddrs_str:gmatch("[^%s]+") do
      log(ipaddr)
      table.insert(splash.ipaddrs,ipaddr)
    end
    
  end
  
  luci.template.render("commotion-splash/splash", {splash=splash, err=error_info})
end

function config_submit()
  local error_info = {}
  local list = list_ifaces()
  local settings = {
    leasetime = luci.http.formvalue("cbid.commotion-splash.leasetime")
  }
  local range

  for _, opt in pairs({'selected_zones','whitelist','blacklist','ipaddrs'}) do
    if type(luci.http.formvalue("cbid.commotion-splash." .. opt)) == "string" then
      settings[opt] = {luci.http.formvalue("cbid.commotion-splash." .. opt)}
    elseif type(luci.http.formvalue("cbid.commotion-splash." .. opt)) == "table" then
      settings[opt] = luci.http.formvalue("cbid.commotion-splash." .. opt)
    else
      DIE("splash: invalid parameters")
      return
    end
  end
  
  --input validation and sanitization
  if (not settings.leasetime or settings.leasetime == '' or not is_uint(settings.leasetime)) then
    error_info.leasetime = "Clearance time must be an integer greater than zero"
  end
  
  for _, selected_zone in pairs(settings.selected_zones) do
    if selected_zone and selected_zone ~= "" and not list.zone_to_iface[selected_zone] then
      DIE("Invalid submission...zone " .. selected_zone .. " doesn't exist")
      return
    end
  end
  
  for _, mac in pairs(settings.whitelist) do
    if mac and mac ~= "" and not is_macaddr(mac) then
      error_info.whitelist = "Whitelist entries must be a valid MAC address"
    end
  end
  
  for _, mac in pairs(settings.blacklist) do
    if mac and mac ~= "" and not is_macaddr(mac) then
      error_info.blacklist = "Blacklist entries must be a valid MAC address"
    end
  end
  
  for _, ipaddr in pairs(settings.ipaddrs) do
    if ipaddr and ipaddr ~= "" and is_ip4addr_cidr(ipaddr) then
      range = true
    elseif ipaddr and ipaddr ~= "" and not is_ip4addr(ipaddr) then
      error_info.ipaddrs = "Entry must be a valid IPv4 address or address range in CIDR notation"
    end
  end
  
  --finish
  if next(error_info) then
    local list = list_ifaces()
    settings.zones={}
    for zone, iface in pairs(list.zone_to_iface) do
      table.insert(settings.zones,zone)
    end
    error_info.notice = "Invalid entries. Please review the fields below."
    config_splash(error_info, settings)
    return
  else
    --set new values
    local options = {
      gw_ifaces = '',
      ipaddrs = '',
      redirect = settings.redirect and ("RedirectURL " .. settings.redirect) or "",
      leasetime = settings.leasetime,
      blacklist = '',
      whitelist = ''
    }
    local new_conf_tmpl = [[${gw_ifaces}

FirewallRuleSet authenticated-users {
  FirewallRule allow all
}

FirewallRuleSet preauthenticated-users {
  FirewallRule allow tcp port 53
  FirewallRule allow udp port 53

  FirewallRule allow to 101.0.0.0/8
  FirewallRule allow to 102.0.0.0/8
  FirewallRule allow to 103.0.0.0/8
  FirewallRule allow to 5.0.0.0/8
  ${ipaddrs}
}

EmptyRuleSetPolicy users-to-router allow

GatewayName Commotion
${redirect}
MaxClients 100
ClientIdleTimeout ${leasetime}
ClientForceTimeout ${leasetime}

BlockedMACList ${blacklist}
TrustedMACList ${whitelist}
]]

    local gw_iface = "GatewayInterface ${iface}"
    local ipaddr = "FirewallRule allow from ${ip_cidr} #FirewallRule preauthenticated-users"
    
    for _, selected_zone in pairs(settings.selected_zones) do
      if selected_zone and selected_zone ~= '' then
        options.gw_ifaces = options.gw_ifaces .. printf(gw_iface, {iface=list.zone_to_iface[selected_zone]}) .. "\n"
      end
    end
    
    for _, ip_cidr in pairs(settings.ipaddrs) do
      if ip_cidr and ip_cidr ~= '' then
	options.ipaddrs = options.ipaddrs .. printf(ipaddr, {ip_cidr=ip_cidr}) .. "\n"
      end
    end
    
    first = true; for _, mac in pairs(settings.whitelist) do
      if mac and mac ~= '' then
        if first then first = false else options.whitelist = options.whitelist .. ',' end
        options.whitelist = options.whitelist .. mac
      end
    end
    
    first = true; for _, mac in pairs(settings.blacklist) do
      if mac and mac ~= '' then
        if first then first = false else options.blacklist = options.blacklist .. ',' end
        options.blacklist = options.blacklist .. mac
      end
    end
    
    local new_conf = printf(new_conf_tmpl, options)
    if not nixio.fs.writefile("/etc/nodogsplash/nodogsplash.conf",new_conf) then
      log("splash: failed to write nodogsplash.conf")
    end
    
    luci.http.redirect(".")
  end
end