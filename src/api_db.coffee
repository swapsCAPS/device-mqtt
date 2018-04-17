randomstring = require 'randomstring'
isJson       = require 'is-json'
debug        = (require 'debug') "device-mqtt:api_db"

QOS = 2
COLLECTIONS_TOPIC = 'collections'
COLLECTION_POSITION = 2
GLOBAL_COLLECTION_POSITION = 2

module.exports = ({ mqttInstance, socket, socketId }) ->
	throw new Error 'No mqtt connection provided!' unless mqttInstance
	throw new Error 'ClientId must be provided!' unless socketId
	DB_REGEX = new RegExp "^#{socketId}\/collections\/(.)+$"
	GLOBAL_REGEX = new RegExp "^global\/collections\/(.)+$"

	_mqtt = mqttInstance
	_socket = socket

	createCollection = (collectionName, localState, collectionObjCb) ->
		singleObjCollTopic = "#{socketId}/#{COLLECTIONS_TOPIC}/#{collectionName}"
		debug "createCollection", singleObjCollTopic
		collectionObjCb(_createCollectionObject singleObjCollTopic, localState)

	createGlobalCollection = (collectionName, localState, collectionObjCb) ->
		singleGlobalObjCollTopic = "global/collections/#{collectionName}"
		collectionObjCb(_createCollectionObject singleGlobalObjCollTopic, localState)

	_createCollectionObject = (singleObjCollTopic, localState) ->
		collectionObj = {}

		# Create methods for collectionObj
		# ADD
		collectionObj.add = ({ key, value }, done) ->
			if localState[key]
				return done new Error "Key `#{key}` already existent!"

			localState[key] = value
			value = JSON.stringify value if (_isJson value) || (Array.isArray value)

			_updateCollectionObject singleObjCollTopic, localState, ->
				_mqtt.pub "#{singleObjCollTopic}/#{key}",
				value,
				{ qos: QOS, retain: true },
				(error) ->
					return done error if error
					done()

		# REMOVE
		collectionObj.remove = (key, done) ->
			if !localState[key]
				return done new Error "Cannot remove key `#{key}`: not existent!"

			delete localState[key]

			_updateCollectionObject singleObjCollTopic, localState, ->
				_mqtt.pub "#{singleObjCollTopic}/#{key}",
				null,
				{ qos: QOS, retain: true },
				(error) ->
					return done error if error
					done()

		# UPDATE
		collectionObj.update = ({ key, value }, done) ->
			if !localState[key]
				return done new Error "Cannot update key `#{key}`: not existent!"

			localState[key] = value
			value = JSON.stringify value if (_isJson value) || (Array.isArray value)

			_updateCollectionObject singleObjCollTopic, localState, ->
				_mqtt.pub "#{singleObjCollTopic}/#{key}",
				value,
				{ qos: QOS, retain: true },
				(error) ->
					return done 'error', error if error
					done()


		# GET
		collectionObj.get = (key) ->
			return null if not localState[key]
			return JSON.parse localState[key] if isJson localState[key]
			return localState[key]

		# GET ALL
		collectionObj.getAll = ->
			return localState

		return collectionObj

	_isJson = (object) ->
		return isJson object, [passObjects=true]

	_updateCollectionObject = (singleObjCollTopic, localState, cb) ->
		_mqtt.pub singleObjCollTopic,
			JSON.stringify(localState),
			{ qos: QOS, retain: true },
			(error) ->
				return done error if error
				cb()

	handleMessage = (topic, message, collectionType) ->
		switch collectionType
			when 'local'  then _handleLocalCollections topic, message
			when 'global' then _handleGlobalCollections topic, message

	_handleLocalCollections = (topic, message) ->
		singleItemCollTopicRegex = new RegExp "^#{socketId}\/collections\/(.)+\/(.)+$"
		collectionName = _extractCollectionName topic

		if singleItemCollTopicRegex.test topic
			message = JSON.parse message if isJson message
			_socket.emit "collection:#{collectionName}", message
		else
			message = JSON.parse message
			_socket.emit 'collection', collectionName, message

	_handleGlobalCollections = (topic, message) ->
		globalSingleItemCollTopicRegex = new RegExp "^global\/collections\/(.)+\/(.)+$"
		collectionName = _extractGlobalCollectionName topic

		if globalSingleItemCollTopicRegex.test topic
			message = JSON.parse message if isJson message
			_socket.emit "global:collection:#{collectionName}", message
		else
			message = JSON.parse message
			_socket.emit 'global:collection', collectionName, message

	_extractCollectionName = (topic) ->
		(topic.split '/')[COLLECTION_POSITION]

	_extractGlobalCollectionName = (topic) ->
		(topic.split '/')[GLOBAL_COLLECTION_POSITION]

	return {
		createCollection
		createGlobalCollection
		handleMessage
		dbRegex: DB_REGEX
		globalRegex: GLOBAL_REGEX
	}
