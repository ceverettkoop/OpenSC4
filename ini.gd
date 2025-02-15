extends Node
class_name INI

var sections = {}
var file_path : String

func _init(path: String):
	file_path = path
	var file = FileAccess.open(file_path, FileAccess.READ)
	var err = FileAccess.get_open_error()
	var current_section = ""
	if err != OK:
		Logger.error("Couldn't load file %s. Error: %s " % [file_path, err] )
		return
	while ! file.eof_reached():
		var line = file.get_line()
		line = line.strip_edges(true, true)
		if line.length() == 0:
			continue
		if line[0] == '#' or line[0] == ';':
			continue
		if line[0] == '[':
			current_section = line.substr(1, line.length() - 2)
			sections[current_section] = {}
		else:
			var key = line.split('=')[0]
			var value = line.split('=')[1]
			sections[current_section][key] = value
	
	DebugUtils.print_dict(sections, self)
	

func save_file():
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	for section in sections.keys():
		file.store_line('[' + section + ']')
		for line in sections[section].keys():
			file.store_line(line + '=' + sections[section][line])
		
