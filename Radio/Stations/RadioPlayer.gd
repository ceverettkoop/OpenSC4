extends AudioStreamPlayer

const path_to_radio: String = '/Radio/Stations/Region/Music/%s'

var current_music 
var music_list = []
var rng = RandomNumberGenerator.new()

func _init():
	self.load_music_files()

func _ready():
	self.connect("finished",Callable(self,"play_music"))

func play_music():
	if len(self.music_list) != 0:
		self.current_music = self.music_list[rng.randi_range(0, len(self.music_list)- 1)]
		var file = FileAccess.open(Core.game_dir + path_to_radio % self.current_music, FileAccess.READ)
		if file != null:
			var audiostream = AudioStreamMP3.new()
			audiostream.set_data(file.get_buffer(file.get_length()))
			self.set_stream(audiostream)
			self.play()

func load_music_files():
	# Load the music list
	var dir = DirAccess.open(Core.game_dir + '/Radio/Stations/Region/Music')
	var err = DirAccess.get_open_error()
	if err != OK:
		print('Error opening radio directory: %s' % err)
		return
	dir.list_dir_begin() # TODOGODOT4 fill missing arguments https://github.com/godotengine/godot/pull/40547
	while true:
		var file = dir.get_next()
		if file == "":
			break
		if file.ends_with('.mp3'):
			self.music_list.append(file)
	dir.list_dir_end()

