extends GZWinBtn

func _init(attributes: Dictionary):
    super._init(attributes)
    self.name = "RegionManagementButton"
    self.toggled_on.connect(_on_toggled_on)
    self.toggled_off.connect(_on_toggled_off)


#TODO: Use notifications instead of signals for greater flexibility?
func _on_toggled_on():
    $"../../RegionSubmenu".set_visible(true)

func _on_toggled_off():
    $"../../RegionSubmenu".set_visible(false)
