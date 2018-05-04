# (require 'leaked-handles').set {
# 	fullStack: true
# 	timeout: 30000
# 	debugSockets: true
# }

EventEmitter2 = require('eventemitter2').EventEmitter2
mqtt          = require 'mqtt'
http          = require "http"
MqttDecorator = require './MqttDecorator'
fs            = require 'fs'
os           = require 'os'
debug         = require('debug') "device-mqtt:main"

currentClientId   = 0
currentSocketId   = 0
MAIN_TOPIC        = 'commands'
COLLECTIONS_TOPIC = 'collections'
QOS               = 0

getIps = ->
	ifaces = os.networkInterfaces()

	eth0IP  = ifaces.eth0?[0].address  or null
	tun0IP  = ifaces.tun0?[0].address  or null
	wwan0IP = ifaces.wwan0?[0].address or null
	ppp0IP  = ifaces.ppp0?[0].address  or null

	{ eth0IP, tun0IP, ppp0IP, wwan0IP }


module.exports = ({ host, port, clientId, tls = {}, extraOpts = {} }) ->
	ACTIONS_TOPIC               = "#{MAIN_TOPIC}/#{clientId}/+"
	SINGLE_ITEM_DB_TOPIC        = "#{clientId}/collections/+"
	OBJECT_DB_TOPIC             = "#{clientId}/collections/+/+"
	GLOBAL_OBJECT_DB_TOPIC      = "global/collections/+"
	SINGLE_ITEM_GLOBAL_DB_TOPIC = "global/collections/+/+"

	throw new Error 'clientId must be provided' unless clientId
	throw new Error 'clientId must not include a `/`' if -1 isnt clientId.indexOf '/'

	api_commands = null
	api_db       = null

	_client           = new EventEmitter2
	_client.connected = false
	_client.id        = ++currentClientId

	_socket    = new EventEmitter2 wildcard: true, delimiter: '/'
	_socket.id = ++currentSocketId
	_mqtt      = null

	connect = (will) ->
		connectionOptions = {}
		_mqttUrl = "mqtt://#{host}:#{port}"

		if Object.keys(tls).length
			connectionOptions = Object.assign {}, connectionOptions, _loadTlsFiles tls
			_mqttUrl = "mqtts://#{host}:#{port}"

		if Object.keys(extraOpts).length
			connectionOptions = Object.assign {}, connectionOptions, extraOpts

		if will
			will = Object.assign {}, will, { qos: 2, retain: true }
			connectionOptions =
				Object.assign {}, connectionOptions, { clientId, clean: false, will }
		else
			connectionOptions =
				Object.assign {}, connectionOptions, { clientId, clean: false }

		debug "Connecting to MQTT with url #{_mqttUrl} and options", connectionOptions
		_mqtt = mqtt.connect _mqttUrl, connectionOptions
		_mqtt = MqttDecorator _mqtt

		_init _mqtt
		_initApis _mqtt, clientId
		_initHTTP console.log

	destroy = (cb) ->
		debug "[MQTT client] Ending"
		_mqtt.end (error) ->
			debug "[MQTT client] Ended"
			cb? error

	customPublish = ({ topic, message, opts }, cb) ->
		_mqtt.publish topic, message, opts, cb

	customSubscribe = ({ topic, opts }, cb) ->
		_mqtt.subscribe topic, opts, cb

	_loadTlsFiles = ({ key, ca, cert }) ->
		return {
			key: fs.readFileSync key
			ca: [fs.readFileSync ca]
			cert: fs.readFileSync cert
		}

	_initApis = (_mqtt) ->
		api_commands = (require './api_commands')(
			mqttInstance: _mqtt
			socket: _socket
			socketId: clientId
		)

		api_db = (require './api_db')(
			mqttInstance: _mqtt
			socket: _socket
			socketId: clientId
		)

	_subFirstTime = (cb) ->
		_startListeningToMessages()
		topics = [
			ACTIONS_TOPIC
			SINGLE_ITEM_DB_TOPIC
			OBJECT_DB_TOPIC
			GLOBAL_OBJECT_DB_TOPIC
			SINGLE_ITEM_GLOBAL_DB_TOPIC
		]

		debug "Subscribing to topics for first time: #{topics}"

		_mqtt.sub(topics,
			{ qos: QOS },
			(error, granted) ->
				if error
					errorMsg = "Error subscribing to actions topic. Reason: #{error.message}"
					return cb new Error errorMsg
				debug "Subscribed correctly to topics #{topics}"
				cb()
		)

	_startListeningToMessages = ->
		debug "Setting messageHandler"
		_mqtt.on 'message', _messageHandler

	_messageHandler = (topic, message) ->
		{ responseRegex, actionRegex } = api_commands
		{ dbRegex, globalRegex } = api_db

		topic = topic.toString()
		message = message.toString()

		if responseRegex.test topic
			debug "Received response message: #{topic}"
			api_commands.handleMessage topic, message, 'result'
		else if actionRegex.test topic
			debug "Received action message: #{topic}"
			api_commands.handleMessage topic, message, 'action'
		else if dbRegex.test topic
			debug "Received db message: #{topic}"
			api_db.handleMessage topic, message, 'local'
		else if globalRegex.test topic
			debug "Received global message: #{topic}"
			api_db.handleMessage topic, message, 'global'
		else
			debug "Received other message: #{topic}"
			_socket.emit topic, message

	_createSocket = ->
		debug "Create socket", _socket.id
		{ send, sendHTTP } = api_commands
		{ createCollection, createGlobalCollection } = api_db

		_socket.send                   = send
		_socket.sendHTTP               = sendHTTP
		_socket.createCollection       = createCollection
		_socket.createGlobalCollection = createGlobalCollection
		_socket.customPublish          = customPublish
		_socket.customSubscribe        = customSubscribe
		_socket

	_init = (mqttInstance) ->
		_onConnection = (connack) ->
			_client.connected = true

			_subFirstTime (error) ->
				_client.emit 'error', error if error
				_client.emit 'connected', _createSocket()

		_onReconnect = ->
			debug "[MQTT client] reconnect"
			_client.emit 'reconnecting'

		_onClose = ->
			debug "[MQTT client] close"
			_client.emit 'disconnected'
			_socket.emit 'disconnected'
			debug "Removing message handler"
			_mqtt.removeListener 'message', _messageHandler
			_client.connected = false

		_onError = (error) ->
			debug "[MQTT client] error: #{error.message}"
			_client.emit 'error', error

		mqttInstance.on 'error',     _onError
		mqttInstance.on 'connect',   _onConnection
		mqttInstance.on 'reconnect', _onReconnect
		mqttInstance.on 'close',     _onClose

	_initHTTP = (cb) ->
		server = http.createServer (req, res) ->
			res.writeHead 200, "Content-Type": "application/json"
			res.end JSON.stringify yeah: "boi"
			_messageHandler req.topic, req.message

		server.listen ->
			port = server.address().port
			console.log "port", port
			_mqtt.pub "#{clientId}/ip", JSON.stringify({ ips: getIps(), port }),
				retain: true
				qos:    0
			, (error) ->
				console.log "error", error



	_createClient = ->
		_client.connect = connect
		_client.destroy = destroy
		_client

	return _createClient()
