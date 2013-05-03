module("luci.controller.commotion-splash.splash", package.seeall)

require "luci.sys"
require "commotion_helpers"

function index()
	entry({"admin", "services", "splash"}, call("config_splash"), _("Captive Portal"), 90).dependent=true
	entry({"admin", "services", "splash", "splashtext" }, form("commotion-splash/splashtext"), _("Splashtext"), 10).dependent=true
	entry({"admin", "services", "splash", "submit" }, call("config_submit")).dependent=true
end

function config_splash()
  local ap_iface = luci.sys.exec("ubus call network.interface.ap status |grep '\"device\"' | cut -d '\"' -f 4")
  local secAp_iface = luci.sys.exec("ubus call network.interface.secAp status |grep '\"device\"' | cut -d '\"' -f 4")
  local plug_iface = luci.sys.exec("ubus call network.interface.plug status |grep '\"device\"' | cut -d '\"' -f 4")
  local plug1_iface = luci.sys.exec("ubus call network.interface.plug1 status |grep '\"device\"' | cut -d '\"' -f 4")
  local plug2_iface = luci.sys.exec("ubus call network.interface.plug2 status |grep '\"device\"' | cut -d '\"' -f 4")
  
  luci.template.render("commotion-splash/splash", {ap=ap_iface, secAp=secAp_iface, plug=plug_iface, plug1=plug1_iface, plug2=plug2_iface})
end