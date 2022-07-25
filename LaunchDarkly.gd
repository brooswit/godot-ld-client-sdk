# This node is intended to be autoloaded as a singleton
# https://docs.godotengine.org/en/stable/tutorials/scripting/singletons_autoload.html

extends Node

const version = "0.0.1"

signal feature_store_updated

var featureStore = {}

var config = {
	"stream_uri":"clientstream.launchdarkly.com",
	"dev_stream_path":"/meval/"
}
var mobileKey = null
var userObject = null

var isConfigured = false
var isIdentified = false
var isReady = false
var shouldRestartStream = false

var httpclient = HTTPClient.new()
var response_body = PoolByteArray()
var stream_event_name = null
var stream_event_data = null

func configure(newMobileKey):
	if mobileKey == newMobileKey:
		return
	mobileKey = newMobileKey
	isConfigured = true
	shouldRestartStream = true

func identify(newUserObject):
	if !areUsersDifferent(userObject, newUserObject):
		return
	userObject = deepCopy(newUserObject)
	isIdentified = true
	shouldRestartStream = true

func variation(flagKey, fallbackValue):
	if !featureStore.has(flagKey):
		return fallbackValue
	return featureStore[flagKey].value

###############################################################################
#### LD util
###############################################################################

func areUsersDifferent(userA, userB):
	return !deepEqual(userA, userB)

###############################################################################
#### Godot built-in methods
###############################################################################

func _process(delta):
	var domain = config.stream_uri
	var port = 443
	var use_ssl = true
	var verify_host = false
	var url_after_domain = config.dev_stream_path
	
	var user_base64 = Marshalls.utf8_to_base64( JSON.print(userObject) )
	
	httpclient.poll()
	var httpclient_status = httpclient.get_status()
	
	# Handle errors first
	var httpclient_error = false
	if httpclient_status == HTTPClient.STATUS_CANT_RESOLVE:
		print("LDClient: ...Cannot resolve host!")
		httpclient_error = true
	elif httpclient_status == HTTPClient.STATUS_CONNECTION_ERROR:
		print("LDClient: ...Connection error occurred!")
		httpclient_error = true
	elif httpclient_status == HTTPClient.STATUS_SSL_HANDSHAKE_ERROR:
		print("LDClient: ...SSL handshake error!")
		httpclient_error = true
	elif httpclient_status == HTTPClient.STATUS_CANT_CONNECT:
		print("LDClient: ...Cannot connect to host!")
		httpclient_error = true
	
	# restart stream if error or if should restart
	if httpclient_error or shouldRestartStream:
		shouldRestartStream = false
		isReady = false
		httpclient.close()
		return
	
	if httpclient_status == HTTPClient.STATUS_DISCONNECTED:
		if isConfigured:
			var err = httpclient.connect_to_host(domain, port, use_ssl, verify_host)
			if err != OK:
				print("LDClient: Unable to open connection!")
		return
	
	if httpclient_status == HTTPClient.STATUS_RESOLVING:
		return
	if httpclient_status == HTTPClient.STATUS_CONNECTING:
		return
		
	if httpclient_status == HTTPClient.STATUS_CONNECTED:
		if isIdentified:
			var additional_headers = ["Authorization: " + mobileKey]
			var err = httpclient.request(HTTPClient.METHOD_GET, url_after_domain + user_base64, additional_headers)
			if err != OK:
				print("LDClient: Unable to request!")
			return
	
	if httpclient_status == HTTPClient.STATUS_REQUESTING:
		return
	
	if httpclient_status == HTTPClient.STATUS_BODY || httpclient.has_response():
		var chunk = httpclient.read_response_body_chunk()
		if(chunk.size() == 0):
			return
		else:
			response_body = response_body + chunk
			
		var body = response_body.get_string_from_utf8()
		if body:
			response_body.resize(0)
			var lines = body.split("\n", false, 0)
			for line in lines:
				var args = line.split(":", false, 1)
				if args.size() != 0:
					if args[0] == "event":
						stream_event_name = args[1]
						# print("event received...")
					if args[0] == "data":
						stream_event_data = JSON.parse(args[1]).result
						# print("event data received... " + args[1])
			
			if stream_event_name != null and stream_event_data != null:
				if stream_event_name == "put":
					featureStore = stream_event_data
					self.emit_signal("feature_store_updated")
				stream_event_name = null
				stream_event_data = null

func _ready():
	print("LaunchDarkly Godot SDK" + version)

###############################################################################
#### Util
###############################################################################

func deepCopy(v):
	if !isObject(v):
		return v
	
	var newCopy = {}
	for key in v:
		newCopy[key] = deepCopy(v[key])
	
	return newCopy

func deepEqual(a, b):
	# if the inputs are litterally equal, then the inputs are equal
	if a == b:
		return true
	
	# if the inputs are objects then continue, otherwise the values cannot be equal
	if (!isObject(a) || !isObject(b)):
		return false
	
	# before comparing, make sure the objects aren't looping/self-referencing
	if detectLoop(a):
		return false
	if detectLoop(b):
		return false
	
	var keyMap = {}
	for key in a:
		keyMap[key] = true
	for key in b:
		keyMap[key] = true
	
	for key in keyMap:
		if !deepEqual(a[key], b[key]):
			return false
	
	return true

func detectLoop(v):
	return false #TODO

func isObject(v):
	return typeof(v) == TYPE_DICTIONARY
	# TODO ADD MORE TYPES
