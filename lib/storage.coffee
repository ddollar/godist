crypto = require("crypto")
fs     = require("fs")
knox   = require("knox")
qs     = require("querystring")
uuid   = require("node-uuid")

class Storage

  constructor: () ->
    @knox = knox.createClient
      key:    process.env.AWS_ACCESS
      secret: process.env.AWS_SECRET
      bucket: process.env.S3_BUCKET

  create: (filename, data, cb) ->
    @knox.putBuffer new Buffer(data, "binary"), filename, cb

  exists: (filename, cb) ->
    @knox.headFile filename, (err, res) ->
      cb err, (res.statusCode != 404)

  get: (filename, cb) ->
    @knox.getFile filename, (err, get) ->
      cb null, get

module.exports.init = () ->
  new Storage()
