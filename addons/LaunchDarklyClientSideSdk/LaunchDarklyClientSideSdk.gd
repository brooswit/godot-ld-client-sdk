extends Node

const version = "0.0.12"
const stream_path = "/meval/"
const event_path = "/mobile"

signal feature_store_updated

# STATE FLAGS

# STATE VARIABLES
var now = OS.get_system_time_msecs()
var featureStore = {}
var mobileKey = null
var userObject = null

# FEATURE REQUESTOR
var stream_httpclient = HTTPClient.new()
var response_body = PoolByteArray()
var stream_event_name = null
var stream_event_data = null

# FEATURE REQUESTOR STATE FLAGS
var isConfigured = false
var isIdentified = false
var shouldRestartStream = false

# EVENT PROCESSOR
var event_httpclient = HTTPClient.new()

# EVENT PROCESSOR STATE FLAGS
var shouldFlush = false
var eventFlusherPayloads = []

## CONFIG OPTIONS
var sendEvents = true
var inlineUsers = false
var stream_uri = "clientstream.launchdarkly.com"
var event_uri = "mobile.launchdarkly.com"

###############################################################################
#### LD SDK public methods
###############################################################################

func configure(newMobileKey, options):
	if mobileKey == newMobileKey:
		return
	
	if options.has("sendEvents"):
		sendEvents = options.sendEvents
	if options.has("inlineUsers"):
		inlineUsers = options.inlineUsers
	
	mobileKey = newMobileKey
	isConfigured = true
	shouldRestartStream = true

func identify(newUserObject):
	newUserObject.key = str(newUserObject.key)
	if !_areUsersDifferent(userObject, newUserObject):
		return
	userObject = _deepCopy(newUserObject)
	
	isIdentified = true
	shouldRestartStream = true
	
	_enqueueAnalyticEvent({
		"kind": "identify",
		"key": userObject.key,
		"user": userObject,
		"creationDate": now,
	})
	

func variation(flagKey, fallbackValue):
	var default = fallbackValue
	var flag = null
	var variation = null
	var value = default

	if featureStore.has(flagKey):
		flag = featureStore[flagKey]
		value = flag.value
		variation = flag.variation
	
	var event = {
		"kind": "feature",
		"key": flagKey,
		"user": userObject,
		"value": value,
		"variation": variation,
		"default": default,
		"creationDate": now
	}
	if userObject and userObject.has("anonymous"):
		event.contextKind = _userContextKind(userObject);
	if flag:
		event.version = flag.version
		event.trackEvents = flag.trackEvents
		if flag.has("debugEventsUntilDate"):
			event.debugEventsUntilDate = flag.debugEventsUntilDate
	# if (includeReasons or (flag and flag.trackReasons)) and detail:
	# 	event.reason = detail.reason
	
	_enqueueAnalyticEvent(event)

	return value

func flush():
	shouldFlush = true

###############################################################################
#### LD private methods
###############################################################################

func _areUsersDifferent(userA, userB):
	return !_deepEqual(userA, userB)

func _userContextKind(user):
	if user.anonymous:
		return "anonymousUser"
	else:
		return "user"

###############################################################################
#### Feature Requestor
#### Designed to use iOS/Android SDK's flag delivery architecture
###############################################################################

func _manageFeatureRequestorConnection():
	var port = 443
	var use_ssl = true
	var verify_host = false

	var domain = stream_uri
	var url_after_domain = stream_path
	
	stream_httpclient.poll()
	var stream_httpclient_status = stream_httpclient.get_status()
	
	# Handle errors first
	var stream_httpclient_error = false
	if stream_httpclient_status == HTTPClient.STATUS_CANT_RESOLVE:
		print("LDClient: ...Cannot resolve host!")
		stream_httpclient_error = true
	elif stream_httpclient_status == HTTPClient.STATUS_CONNECTION_ERROR:
		print("LDClient: ...Connection error occurred!")
		stream_httpclient_error = true
	elif stream_httpclient_status == HTTPClient.STATUS_SSL_HANDSHAKE_ERROR:
		print("LDClient: ...SSL handshake error!")
		stream_httpclient_error = true
	elif stream_httpclient_status == HTTPClient.STATUS_CANT_CONNECT:
		print("LDClient: ...Cannot connect to host!")
		stream_httpclient_error = true
	
	# restart stream if error or if should restart
	if stream_httpclient_error or shouldRestartStream:
		shouldRestartStream = false
		stream_httpclient.close()
		return false
	
	if stream_httpclient_status == HTTPClient.STATUS_DISCONNECTED:
		if isConfigured:
			var err = stream_httpclient.connect_to_host(domain, port, use_ssl, verify_host)
			if err != OK:
				print("LDClient: Unable to open connection!")
		return false
	
	if stream_httpclient_status == HTTPClient.STATUS_RESOLVING:
		return false
	if stream_httpclient_status == HTTPClient.STATUS_CONNECTING:
		return false
		
	if stream_httpclient_status == HTTPClient.STATUS_CONNECTED:
		if isIdentified:
			var user_base64 = Marshalls.utf8_to_base64( JSON.print(userObject) )
			var additional_headers = ["Authorization: " + mobileKey]
			var err = stream_httpclient.request(HTTPClient.METHOD_GET, url_after_domain + user_base64, additional_headers)
			if err != OK:
				print("LDClient: Unable to request!")
			return false
	
	if stream_httpclient_status == HTTPClient.STATUS_REQUESTING:
		return false
	
	if stream_httpclient_status == HTTPClient.STATUS_BODY || stream_httpclient.has_response():
		return true
	
	# This should never occur.
	return false

func _consumeFeatureRequestorStream():
	var chunk = stream_httpclient.read_response_body_chunk()
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
			# else:
				# print("unknown event: " + event + " with data " + JSON.print(data))
				# print("debug feature store: " + JSON.print(featureStore))
		if featureStoreUpdated:
			self.emit_signal("feature_store_updated")

func _consumeFeatureEventsFromFeatureRequestorStream():
	var body =_consumeFeatureRequestorStream()
	var featureEvents = _parseFeatureEvents(body)
	return featureEvents

func _processFeatureRequestor():
	if !_manageFeatureRequestorConnection():
		return false
	var featureEvents = _consumeFeatureEventsFromFeatureRequestorStream()
	if featureEvents:
		_handleFeatureEvents(featureEvents)

###############################################################################
#### Analytic Event Processor
#### Mostly ported from JS client-side SDK
###############################################################################

var lastFlush = now
var eventQueue = []
var summarizationCounters = {}
var summarizationStartDate = 0
var summarizationEndDate = 0

func _summarizeEvent(event):
	if event.kind == "feature":
		var counterKey = str(event.key) + ":" + str(event.variation) + ":" + str(event.version)
		if summarizationCounters.has(counterKey):
			summarizationCounters[counterKey].count += 1
		else:
			summarizationCounters[counterKey] = {
				"count": 1,
				"key": event.key,
				"variation": event.variation,
				"version": event.version,
				"value": event.value,
				"default": event.default
			}
		if summarizationStartDate == 0 || event.creationDate < summarizationStartDate:
			summarizationStartDate = event.creationDate
		if event.creationDate > summarizationEndDate:
			summarizationEndDate = event.creationDate

func _getSummary():
	var flagsOut = {}
	var empty = true
	for index in summarizationCounters:
		var counter = summarizationCounters[index]
		var flag
		if flagsOut.has(counter.key):
			flag = flagsOut[counter.key]
		else:
			flag = {
				"default": counter.default,
				"counters": []
			}
		flagsOut[counter.key] = flag
		var counterOut = {
			"value": counter.value,
			"count": counter.count
		}
		if counter.has("variation") && counter.variation != null:
			counterOut.variation = counter.variation
		if counter.version:
			counterOut.version = counter.version
		else:
			counterOut.unknown = true
		flag.counters = flag.counters + [counterOut]
		empty = false
	if empty:
		return null
	return {
		"startDate": summarizationStartDate,
		"endDate": summarizationEndDate,
		"features": flagsOut,
	}

func _makeOutputEvent(event):
	event = _deepCopy(event)
	if event.kind == "alias":
		return event
	if !inlineUsers and event.kind != 'identify':
		event.userKey = event.user.key
		event.erase("user")
	if event.kind == "feature":
		event.erase("trackEvents")
		event.erase("debugEventsUntilDate")
	return event

func _shouldDebugAnalyticEvent(event):
	if event.has("debugEventsUntilDate"):
		return event.debugEventsUntilDate > now

func _clearSummary():
	summarizationStartDate = 0;
	summarizationEndDate = 0;
	summarizationCounters = {};

func _flush():
	if !sendEvents:
		return
	
	var eventsToSend = _deepCopy(eventQueue)
	var summary = _getSummary()
	_clearSummary()
	if summary:
		summary.kind = "summary"
		eventsToSend = eventsToSend + [summary]
	if eventsToSend.size() == 0:
		return
	# TODO send the events
	eventFlusherPayloads = eventFlusherPayloads + [JSON.print(eventsToSend)]
	eventQueue = []

func _enqueueAnalyticEvent(event):
	var addFullEvent = true
	var addDebugEvent = false
	
	_summarizeEvent(event)
	
	if event.kind == 'feature':
		addFullEvent = event.trackEvents == true
		addDebugEvent = _shouldDebugAnalyticEvent(event)
	
	if addFullEvent:
		eventQueue = eventQueue + [_makeOutputEvent(event)]
	
	if addDebugEvent:
		var debugEvent = _deepCopy(event)
		debugEvent.kind = "debug"
		debugEvent.erase("trackEvents")
		debugEvent.erase("debugEventsUntilDate")
		eventQueue = eventQueue + [debugEvent]

func _manageEventFlusherConnection():
	var port = 443
	var use_ssl = true
	var verify_host = false

	var domain = event_uri
	var url_after_domain = event_path
	
	event_httpclient.poll()
	var event_httpclient_status = event_httpclient.get_status()
	
	if event_httpclient_status == HTTPClient.STATUS_DISCONNECTED:
		if eventFlusherPayloads.size() > 0:
			var err = event_httpclient.connect_to_host(domain, port, use_ssl, verify_host)
			if err != OK:
				print("LDClient: EventFlusher: Unable to open connection!")
		return false
	
	# Handle errors first
	var event_httpclient_error = false
	if event_httpclient_status == HTTPClient.STATUS_CANT_RESOLVE:
		print("LDClient: EventFlusher: ...Cannot resolve host!")
		event_httpclient_error = true
	elif event_httpclient_status == HTTPClient.STATUS_CONNECTION_ERROR:
		print("LDClient: EventFlusher: ...Connection error occurred!")
		event_httpclient_error = true
	elif event_httpclient_status == HTTPClient.STATUS_SSL_HANDSHAKE_ERROR:
		print("LDClient: EventFlusher: ...SSL handshake error!")
		event_httpclient_error = true
	elif event_httpclient_status == HTTPClient.STATUS_CANT_CONNECT:
		print("LDClient: EventFlusher: ...Cannot connect to host!")
		event_httpclient_error = true
	
	# restart event if error or if should restart
	if event_httpclient_error:
		event_httpclient.close()
		return false
	
	var event_httpclient_connecting = false
	if event_httpclient_status == HTTPClient.STATUS_RESOLVING:
		event_httpclient_connecting = true
	if event_httpclient_status == HTTPClient.STATUS_CONNECTING:
		event_httpclient_connecting = true
	
	if event_httpclient_connecting == true:
		return false
		
	if event_httpclient_status == HTTPClient.STATUS_CONNECTED:
		var body = eventFlusherPayloads[0]
		var additional_headers = ["Authorization: " + mobileKey, "Content-Type: application/json", "Content-Length: " + str(body.length())]
		var err = event_httpclient.request(HTTPClient.METHOD_POST, url_after_domain, additional_headers, body)
		if err != OK:
			print("LDClient: EventFlusher: Unable to request!")
		return false
	
	if event_httpclient_status == HTTPClient.STATUS_REQUESTING:
		return false
	
	if event_httpclient_status == HTTPClient.STATUS_BODY || event_httpclient.has_response():
		# print(event_httpclient.get_response_code())
		# print(JSON.print(event_httpclient.get_response_headers()))
		# print(eventFlusherPayloads[0])
		eventFlusherPayloads.remove(0)
		event_httpclient.close()
		return true
	
	# This should never occur.
	return false

func _processAnalyticEventProcessor():
	if sendEvents == false:
		return
	
	if now > lastFlush + 5000 or shouldFlush:
		shouldFlush = false
		lastFlush = now
		_flush()
	
	_manageEventFlusherConnection()

###############################################################################
#### Godot built-in methods
###############################################################################

func _process(delta):
	now = OS.get_system_time_msecs()
	_processFeatureRequestor()
	_processAnalyticEventProcessor()

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
