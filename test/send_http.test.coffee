# (require 'leaked-handles').set {
# 	fullStack: true
# 	timeout: 30000
# 	debugSockets: true
# }

# After running the first test, restart the broker before testing again

async      = require "async"
test       = require 'tape'
devicemqtt = require '../src/index'
{ fork }   = require "child_process"

# Only for pipeline tests
config =
	host: 'toke-mosquitto'
	port: 1883

if process.env.NODE_ENV is 'development'
	config =
		host: 'localhost'
		port: 1883


### Testing template

test 'What component aspect are you testing?', (assert) ->
	actual = 'What is the actual output?'
	expected = 'What is the expected output?'

	assert.equal actual, expected, 'What should the feature do?'

	assert.end()

###############################################################

setup = (clientId) ->
	client = null
	client = devicemqtt(Object.assign {}, config, { clientId })
	return client

forkClient = (clientId) ->
	client = fork "./meta/client.coffee"
	client.send Object.assign({}, config, { clientId })
	return client

teardownForkedClient = (client) ->
	client.kill 'SIGKILL'

teardown = (client, cb) ->
	client.destroy cb

test.only 'Sends action over http', (assert) ->
	# Test data
	expectedResponse = { data: 'somedata' }
	actionToSend =
		action: 'theaction'
		payload: 'payload'
		dest: 'receiver1'

	# Setting up clients
	sender   = setup 'sender1'
	receiver = setup 'receiver1'

	receiver.on 'message', (message) ->
		if message is 'connected'
			sender.connect()

	sender.once 'connected', (socket) ->
		socket.sendHTTP actionToSend
		, (error, response) ->
			console.log "error", error
			console.log "response", response
			assert.deepEqual response, expectedResponse,
				"The response should be equal to #{JSON.stringify expectedResponse}"
			async.parallel [
				(cb) ->
					teardown receiver, cb
				(cb) ->
					teardown sender, cb
			], -> assert.end
		, (error, ack) ->
			assert.equal ack, 'OK',
				'If the sender published an action correctly, the ack should be `OK`'
