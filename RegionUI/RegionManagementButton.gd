extends GZWinBtn

func _init(attributes: Dictionary):
	super._init(attributes)
	self.name = "RegionManagementButton"
	self.connect("toggled_on",Callable(self,"_on_toggled_on"))
	self.connect("toggled_off",Callable(self,"_on_toggled_off"))


#TODO: Use notifications instead of signals for greater flexibility?
func _on_toggled_on():
	$"../../RegionSubmenu".set_visible(true)

func _on_toggled_off():
	$"../../RegionSubmenu".set_visible(false)
