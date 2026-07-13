extends TileMapLayer


var cities : Array = []
var width : int = 0
var height : int = 0

# SC4's region grid is a custom dimetric lattice, not a square/isometric one.
# Godot 3 stored it as the TileMap cell_custom_transform
# Transform2D(90, 18.7, -37.3, 45, 0, 0); Godot 4's TileMapLayer can't represent
# that shear, so we do the coordinate math here instead of via map_to_local().
#   +1 cell in x -> (90, 18.7) px ;  +1 cell in y -> (-37.3, 45) px
const CELL_TRANSFORM := Transform2D(Vector2(90.0, 18.7), Vector2(-37.3, 45.0), Vector2.ZERO)

func region_to_local(cell: Vector2) -> Vector2:
    return CELL_TRANSFORM * cell

func local_to_region(local: Vector2) -> Vector2i:
    var cell := CELL_TRANSFORM.affine_inverse() * local
    return Vector2i(roundi(cell.x), roundi(cell.y))

func init_cities_array(width_, height_):
    self.width = width_
    self.height = height_
    for i in range(width_):
        cities.append([])
        for _j in range(height_):
            cities[i].append(null)

func _unhandled_input(event):
    if event is InputEventMouseButton and event.double_click:
        # Get the grid position
        var grid_position : Vector2i = local_to_region(to_local(get_global_mouse_position()))
        if grid_position.x >= 0 and grid_position.x < width and grid_position.y >= 1 and grid_position.y < height:
            cities[grid_position.x][grid_position.y].open_city()
            
