# This node is intended to be autoloaded as a singleton
# https://docs.godotengine.org/en/stable/tutorials/scripting/singletons_autoload.html

extends Node

const version = "0.0.8"

const stream_path = "/meval/"

signal feature_store_updated

var featureStore = {}

var stream_uri = "clientstream.launchdarkly.com"

var mobileKey = null
var userObject = null

var isConfigured = false
var isIdentified = false
var shouldRestartStream = false

var httpclient = HTTPClient.new()
var response_body = PoolByteArray()
var stream_event_name = null
var stream_event_data = null

###############################################################################
#### LD public methods
###############################################################################

func configure(newMobileKey):
	if mobileKey == newMobileKey:
		return
	mobileKey = newMobileKey
	isConfigured = true
	shouldRestartStream = true

func identify(newUserObject):
	if !_areUsersDifferent(userObject, newUserObject):
		return
	userObject = _deepCopy(newUserObject)
	isIdentified = true
	shouldRestartStream = true

func variation(flagKey, fallbackValue):
	if !featureStore.has(flagKey):
		return fallbackValue
	return featureStore[flagKey].value

###############################################################################
#### LD private methods
###############################################################################

func _areUsersDifferent(userA, userB):
	return !_deepEqual(userA, userB)

###############################################################################
#### Feature Requestor
###############################################################################

func _manageFeatureRequestorConnection():
	var port = 443
	var use_ssl = true
	var verify_host = false

	var domain = stream_uri
	var url_after_domain = stream_path
	
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
		httpclient.close()
		return false
	
	if httpclient_status == HTTPClient.STATUS_DISCONNECTED:
		if isConfigured:
			var err = httpclient.connect_to_host(domain, port, use_ssl, verify_host)
			if err != OK:
				print("LDClient: Unable to open connection!")
		return false
	
	if httpclient_status == HTTPClient.STATUS_RESOLVING:
		return false
	if httpclient_status == HTTPClient.STATUS_CONNECTING:
		return false
		
	if httpclient_status == HTTPClient.STATUS_CONNECTED:
		if isIdentified:
			var user_base64 = Marshalls.utf8_to_base64( JSON.print(userObject) )
			var additional_headers = ["Authorization: " + mobileKey]
			var err = httpclient.request(HTTPClient.METHOD_GET, url_after_domain + user_base64, additional_headers)
			if err != OK:
				print("LDClient: Unable to request!")
			return false
	
	if httpclient_status == HTTPClient.STATUS_REQUESTING:
		return false
	
	if httpclient_status == HTTPClient.STATUS_BODY || httpclient.has_response():
		return true
	
	# This should never occur.
	return false

func _consumeFeatureRequestorStream():
	var chunk = httpclient.read_response_body_chunk()
	if(chunk.size() == 0):
		return
	else:
		response_body = response_body + chunk
	
	var body = response_body.get_string_from_utf8()
	if body:
		response_body.resize(0)
	return body

func _parseFeatureEvents(body):
	var featureEvents
	if body:
		featureEvents = []
		response_body.resize(0)
		var lines = body.split("\n", false, 0)
		for line in lines:
			var args = line.split(":", false, 1)
			if args.size() != 0:
				if args[0] == "event":
					stream_event_name = args[1]
					stream_event_data = null
					# print("event received...")
				if args[0] == "data":
					stream_event_data = JSON.parse(args[1]).result
					# print("event data received... " + args[1])
					featureEvents = featureEvents + [{
						"event": stream_event_name,
						"data": stream_event_data
					}]
					stream_event_name = null
					stream_event_data = null
	return featureEvents

func _handleFeatureEvents(featureEvents):
	var featureStoreUpdated = false
	
	if featureEvents:
		for eventData in featureEvents:
			var event = eventData.event
			var data = eventData.data
			if event == "put":
				featureStore = data
				featureStoreUpdated = true
			elif event == "patch":
				var entry = _deepCopy(featureStore[data.key])
				if entry == null:
					entry = {}
				for key in data:
					if key != "key":
						entry[key] = data[key]
				featureStore[data.key] = entry
				featureStoreUpdated = true
			else:
				print("unknown event: " + event + " with data " + JSON.print(data))
				print("debug feature store: " + JSON.print(featureStore))
		if featureStoreUpdated:
			self.emit_signal("feature_store_updated")

func _consumeFeatureEventsFromFeatureRequestorStream():
	var body =_consumeFeatureRequestorStream()
	var featureEvents = _parseFeatureEvents(body)
	return featureEvents

func _processFeatureRequestor(delta):
	if !_manageFeatureRequestorConnection():
		return false
	var featureEvents = _consumeFeatureEventsFromFeatureRequestorStream()
	if featureEvents:
		_handleFeatureEvents(featureEvents)

###############################################################################
#### Analytic Event Processor
###############################################################################

func _processAnalyticEventProcessor(delta):
	return

###############################################################################
#### Godot built-in methods
###############################################################################

func _process(delta):
	_processFeatureRequestor(delta)
	_processAnalyticEventProcessor(delta)

func _ready():
	print("LaunchDarkly Godot SDK " + version)

###############################################################################
#### Utility methods
###############################################################################

func _deepCopy(v):
	if !_isObject(v):
		return v
	
	var newCopy = {}
	for key in v:
		newCopy[key] = _deepCopy(v[key])
	
	return newCopy

func _deepEqual(a, b):
	# if the inputs are litterally equal, then the inputs are equal
	if a == b:
		return true
	
	# if the inputs are objects then continue, otherwise the values cannot be equal
	if (!_isObject(a) || !_isObject(b)):
		return false
	
	# before comparing, make sure the objects aren't looping/self-referencing
	if _detectLoop(a):
		return false
	if _detectLoop(b):
		return false
	
	var keyMap = {}
	for key in a:
		keyMap[key] = true
	for key in b:
		keyMap[key] = true
	
	for key in keyMap:
		if !_deepEqual(a[key], b[key]):
			return false
	
	return true

func _detectLoop(v):
	return false #TODO

func _isObject(v):
	return typeof(v) == TYPE_DICTIONARY
	# TODO ADD MORE TYPES
