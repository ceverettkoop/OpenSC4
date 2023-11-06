extends GZWinGen

func _init(attributes : Dictionary):
	super._init(attributes)
	self.set_anchors_preset(PRESET_TOP_RIGHT, true)
	self.name = "TopBarSettingsButtonContainer"