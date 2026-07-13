extends GZWinBtn

func _init(attributes : Dictionary):
    super._init(attributes)
    self.name="TopBarSettingsButton"
    self.toggled_on.connect(_on_toggled_on)
    self.toggled_off.connect(_on_toggled_off)

func _on_toggled_on():
    $"../../TopBarSettingsMenu".set_visible(true)

func _on_toggled_off():
    $"../../TopBarSettingsMenu".set_visible(false) 