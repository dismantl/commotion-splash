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
  local splash = {zones={}, selected_zones={}, whitelist={}, blacklist={}, ipaddrs={}}
  local current_ifaces = luci.sys.exec("grep 'GatewayInterface' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 2")
  local list = list_ifaces()
  
  -- get current zone(s) set in nodogsplash --> splash.zone_selected
  for zone, iface in pairs(list.zone_to_iface) do
    splash.zones[zone] = current_ifaces:match(iface) and "selected" or ""
    if current_ifaces:match(iface) then
      table.insert(splash.selected_zones, zone)
    end
  end
  
  -- get splash.leasetime
  splash.leasetime = luci.sys.exec("grep 'ClientIdleTimeout' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 2")
  
  -- get whitelist, blacklist, ipaddrs
  
  luci.template.render("commotion-splash/splash", {splash=splash, err=error_info})
end

function config_submit()
  local error_info = {}
  local list = list_ifaces()
  local settings = {
    leasetime = luci.http.formvalue("cbid.commotion-splash.leasetime")
  }
  local range

  for opt in {'zones','whitelist','blacklist','ipaddrs'} do
    if type(settings[opt]) == "string" then
      settings[opt] = {luci.http.formvalue("cbid.commotion-splash." .. opt)}
    else
      settings[opt] = luci.http.formvalue("cbid.commotion-splash." .. opt)
    end
  end
  
  --input validation and sanitization
  if (not settings.leasetime or settings.leasetime == '' or not is_uint(settings.leasetime)) then
    error_info.leasetime = "Clearance time must be an integer greater than zero"
  end
  
  for zone in settings.zones do
    if zone and zone ~= "" and not list.zone_to_iface[zone] then
      DIE("Invalid submission...zone " .. zone .. " doesn't exist")
      return
    end
  end
  
  for mac in settings.whitelist do
    if mac and mac ~= "" and not is_macaddr(mac) then
      error_info.whitelist = "Whitelist entries must be a valid MAC address"
    end
  end
  
  for mac in settings.blacklist do
    if mac and mac ~= "" and not is_macaddr(mac) then
      error_info.blacklist = "Blacklist entries must be a valid MAC address"
    end
  end
  
  for ipaddr in settings.ipaddrs do
    if ipaddr and ipaddr ~= "" and is_ip4addr_cidr(ipaddr) then
      range = true
    elseif ipaddr and ipaddr ~= "" and not is_ip4addr(ipaddr) then
      error_info.ipaddrs = "Entry must be a valid IPv4 address or address range in CIDR notation"
    end
  end
  
  --finish
  if next(error_info) then
    error_info.notice = "Invalid entries. Please review the fields below."
    config_splash(error_info, settings)
    return
  else
    --set new values
    --luci.sys.exec("sed -i -e s/\"^GatewayInterface [[:alnum:]]*\"/\"GatewayInterface " .. list.zone_to_iface[new_zone] .. '"/ /etc/nodogsplash/nodogsplash.conf')
    local options = {
      gw_ifaces = '',
      ipaddrs = '',
      redirect = settings.redirect and ("RedirectURL " .. settings.redirect) or "",
      leasetime = settings.leastime,
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
TrustedMACList ${whitelist}]]

    local gw_iface = "GatewayInterface ${iface}"
    local ipaddr = "FirewallRule allow from ${ip_cidr}"
    
    for zone in settings.zones do
      options.gw_ifaces = options.gw_ifaces .. printf(gw_iface, {iface=list.zone_to_iface[zone]}) .. "\n"
    end
    
    for ip_cidr in settings.ipaddrs do
      options.ipaddrs = options.ipaddrs .. printf(ipaddr, {ip_cidr=ip_cidr}) .. "\n"
    end
    
    first = true; for mac in settings.whitelist do
      if first then first = false else options.whitelist = options.whitelist .. ',' end
      options.whitelist = options.whitelist .. mac
    end
    
    first = true; for mac in settings.blacklist do
      if first then first = false else options.blacklist = options.blacklist .. ',' end
      options.blacklist = options.blacklist .. mac
    end
    
    local new_conf = printf(new_conf_tmpl, options)
    if not nixio.fs.writefile("/etc/nodogsplash/nodogsplash.conf",new_conf) then
      log("splash: failed to write nodogsplash.conf")
    end
    
    luci.http.redirect(".")
  end
end

function list_ifaces()
  local uci = luci.model.uci.cursor()
  local r = {zone_to_iface = {}, iface_to_zone = {}}
  uci:foreach("network", "interface", 
    function(zone)
      if zone['.name'] == 'loopback' then return end
      local iface = luci.sys.exec("ubus call network.interface." .. zone['.name'] .. " status |grep '\"device\"' | cut -d '\"' -f 4"):gsub("%s$","")
      r.zone_to_iface[zone['.name']]=iface
      r.iface_to_zone[iface]=zone['.name']
    end
  )
  return r
end