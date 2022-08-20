extends Control

var town = null
var user_key = null

var car_scene_path = null

const LAUNCHDARKLY_MOBILE_KEY = "PUT_YOUR_MOBILE_KEY_HERE"

func _ready():
	LaunchDarklyClientSideSdk.configure(LAUNCHDARKLY_MOBILE_KEY, {})
	user_key = OS.get_system_time_msecs()



func _process(_delta):
	if Input.is_action_just_pressed("back"):
		_on_Back_pressed()


func _load_scene(car):
	var tt = load(car).instance()
	tt.set_name("car")
	town = load("res://town_scene.tscn").instance()
	town.get_node("InstancePos").add_child(tt)
	town.get_node("Back").connect("pressed", self, "_on_Back_pressed")
	get_parent().add_child(town)
	
func on_feature_store_updated():
	LaunchDarklyClientSideSdk.disconnect("feature_store_updated", self, "on_feature_store_updated")
	_load_scene(car_scene_path)
	


func _on_Back_pressed():
	if is_instance_valid(town):
		# Currently in the town, go back to main menu.
		town.queue_free()
		show()
	else:
		# In main menu, exit the game.
		get_tree().quit()


func _on_MiniVan_pressed():
	LaunchDarklyClientSideSdk.connect("feature_store_updated", self, "on_feature_store_updated")
	LaunchDarklyClientSideSdk.identify({
		"key": user_key,
		"custom": {
			"vehicle": "mini_van"
		}
	})
	car_scene_path = "res://car_base.tscn"
	hide()


func _on_TrailerTruck_pressed():
	LaunchDarklyClientSideSdk.connect("feature_store_updated", self, "on_feature_store_updated")
	LaunchDarklyClientSideSdk.identify({
		"key": user_key,
		"custom": {
			"vehicle": "trailer_truck"
		}
	})
	car_scene_path = "res://trailer_truck.tscn"
	hide()


func _on_TowTruck_pressed():
	LaunchDarklyClientSideSdk.connect("feature_store_updated", self, "on_feature_store_updated")
	LaunchDarklyClientSideSdk.identify({
		"key": user_key,
		"custom": {
			"vehicle": "tow_truck"
		}
	})
	car_scene_path = "res://tow_truck.tscn"
	hide()
