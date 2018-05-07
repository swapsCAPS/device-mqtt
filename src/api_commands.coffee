randomstring = require 'randomstring'
request      = require "request"
debug        = (require 'debug') "device-mqtt:api_commands"

QOS               = 0
MAIN_TOPIC        = 'commands'
RESPONSE_SUBTOPIC = 'response'
ACTIONID_POSITION = 0
RESPONSE_REGEXP   = new RegExp "^#{MAIN_TOPIC}\/(.)+\/([a-zA-Z0-9])+\/#{RESPONSE_SUBTOPIC}"
ACTION_REGEXP     = new RegExp "^#{MAIN_TOPIC}\/(.)+\/([a-zA-Z0-9])+"

module.exports = ({ mqttInstance, socket, socketId }) ->
	throw new Error 'No mqtt connection provided!' unless mqttInstance
	throw new Error 'ClientId must be provided!' unless socketId

	_socket = socket
	_mqtt   = mqttInstance
	_actionResultCallbacks = {}

	sendHTTP = (message, res) ->
		{ action, dest, payload } = message
		console.log "action", action
		console.log "dest", dest

		# Get ip
		_mqtt.on "message", (topic, ipInfo) ->
			return unless topic is "#{dest}/ip"
			_mqtt.unsubscribe "#{dest}/ip", (error) ->
				console.log "unsubscribe", error

			console.log "ipInfo", ipInfo.toString()

			{ips, port} = JSON.parse ipInfo.toString()

			# Make request to device
			request.post "http://#{ips.tun0IP}:#{port}",
				body:
					action: action
					payload: payload
				json: true
			(error, response, body) ->
				console.log "res error", error
				console.log "res body", body


		_mqtt.subscribe "#{dest}/ip", { qos: 0 }, (error, granted) ->
			console.log "granted", granted
			console.log "error", error

	send = (message, resultCb, mqttCb) ->
		{ action, dest, payload } = message

		debug "Sending action #{action} to #{dest} with payload: #{payload}"
		throw new Error 'No action provided!' if !action
		throw new Error 'No dest provided!' if !dest
		throw new Error 'Action must be a string' if typeof message.action isnt 'string'
		throw new Error 'Dest must be a string' if typeof message.dest isnt 'string'

		actionMessage = JSON.stringify { action, payload, origin: socketId }
		debug "Sending new message: #{actionMessage}"

		actionId = randomstring.generate()
		topic    = _generatePubTopic actionId, message.dest

		###
			Is it important to sub to the response topic before sending the action,
			because there can be a race condition and the sender will never receives
			the response.
		###
		responseTopic = _generateResponseTopic actionId, socketId
		_mqtt.sub responseTopic, { qos: QOS }, (error, granted) ->
			return _socket.emit 'error', error if error
			_actionResultCallbacks[actionId] = resultCb

			_mqtt.pub topic, actionMessage, { qos: QOS }, (error) ->
				if error
					_mqtt.unsubscribe responseTopic, (unsubscribeError) ->
						return _socket.emit 'error', unsubscribeError if unsubscribeError
						return _socket.emit 'error', error

				mqttCb? null, 'OK'

	handleMessage = (topic, message, type) ->
		debug "Received message. Topic: #{topic.toString()}, payload: #{message}, type: #{type}"

		if type is 'result'
			return _handleIncomingResults topic, message

		if type is 'action'
			return _handleIncomingActions topic, message

	_handleIncomingActions = (topic, message) ->
		debug "Received new action. Topic: #{topic} and message: #{message}\n"

		{ action, payload, origin } = JSON.parse message
		actionId = _extractActionId topic

		reply = _generateReplyObject origin, actionId, action

		_socket.emit "action", action, payload, reply
		_socket.emit "action:#{action}", payload, reply

	_handleIncomingResults = (topic, message) ->
		debug "Received new result. Topic: #{topic} and message: #{message}\n"

		{ action, statusCode, data } = JSON.parse message
		actionId = _extractActionId topic

		_mqtt.unsubscribe topic, (error) ->
			return _socket.emit 'error', error if error

			if _actionResultCallbacks[actionId]
				if statusCode is 'OK'
					_actionResultCallbacks[actionId] null, { data }
				else
					_actionResultCallbacks[actionId] { data }
				delete _actionResultCallbacks[actionId]
			else
			if statusCode is 'OK'
				_socket.emit 'response', null, { action, data }
			else
				_socket.emit 'response', { action, data }

	_extractActionId = (topic) ->
		topic = topic.toString()
		actionId = (topic.split '/')[ACTIONID_POSITION]
		return actionId

	_generateReplyObject = (origin, actionId, action) ->
		reply = {}
		reply.send = ({ type, data }, cb) ->
			responseMessage = _generateResponse { type, data, action }

			_mqtt.pub(
				_generateResponseTopic(actionId, origin),
				responseMessage,
				qos: QOS,
				(error) ->
					return cb? error if error
					_mqtt.unsubscribe _generatePubTopic(actionId, socketId), (error) ->
						return cb? error if error
						cb? null, 'OK'
			)

		return reply

	_generateResponseTopic = (actionId, origin) ->
		debug "Generating response topic with actionId #{actionId} and origin #{origin}"
		responseTopic = "#{MAIN_TOPIC}/#{origin}/#{actionId}/#{RESPONSE_SUBTOPIC}"

		debug "Generated response topic: #{responseTopic}"
		return responseTopic

	_generatePubTopic = (actionId, dest) ->
		"#{MAIN_TOPIC}/#{dest}/#{actionId}"

	_generateResponse = ({ type, data = {}, action }) ->
		throw new Error 'No data provided!' if !data
		responseType = (data) -> {
			success: JSON.stringify { statusCode: 'OK', data, action }
			error: JSON.stringify { statusCode: 'ERROR', data, action }
		}

		responseType(data)[type]

	return {
		send
		sendHTTP
		handleMessage
		responseRegex: RESPONSE_REGEXP
		actionRegex: ACTION_REGEXP
	}
