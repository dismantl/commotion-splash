module("luci.controller.commotion-splash.splash", package.seeall)

require "luci.sys"
require "luci.http"
require "commotion_helpers"

function index()
	entry({"admin", "services", "splash"}, call("config_splash"), _("Captive Portal"), 90).dependent=true
	entry({"admin", "services", "splash", "splashtext" }, form("commotion-splash/splashtext"), _("Splashtext"), 10).dependent=true
	entry({"admin", "services", "splash", "submit" }, call("config_submit")).dependent=true
end

function config_splash()
  local splash = {zones={}, whitelist={}, blacklist={}, subnet={}}
  local current_ifaces = luci.sys.exec("grep 'GatewayInterface' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 2")
  local list = list_ifaces()
  
  -- get current zone(s) set in nodogsplash --> splash.zone_selected
  for zone, iface in pairs(list.zone_to_iface) do
    splash.zones[zone]= current_ifaces:match(iface) and "selected" or ""
  end
  
  -- get splash.leasetime
  splash.leasetime = luci.sys.exec("grep 'ClientIdleTimeout' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 2")
  
  -- get whitelist, blacklist, subnet
  
  luci.template.render("commotion-splash/splash", splash)
end

function config_submit()
  local list = list_ifaces()
  local new_zone = luci.http.formvalue("cbid.commotion-splash.zone")
  luci.sys.exec("sed -i -e s/\"^GatewayInterface [[:alnum:]]*$\"/\"GatewayInterface " .. list.zone_to_iface[new_zone] .. "\"/ /etc/nodogsplash/nodogsplash.conf")
end

function list_ifaces()
  local r = {zone_to_iface = {}, iface_to_zone = {}}
  local zones = luci.sys.exec("grep 'config interface' /etc/config/network |cut -d \"'\" -f 2")
  for zone in zones:gmatch("%w+") do
    local iface = luci.sys.exec("ubus call network.interface." .. zone .. " status |grep '\"device\"' | cut -d '\"' -f 4")
    r.zone_to_iface[zone]=iface
    r.iface_to_zone[iface]=zone
  end
  return r
end