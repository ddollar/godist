parse_links = require("parse-links")
request     = require("request")

exports.Github = class Github

  constructor: (@token) ->

  get: (path, cb) ->
    @get_items "https://api.github.com#{path}?access_token=#{@token}&client_id=#{process.env.OAUTH_CLIENT_ID}&client_secret=#{process.env.OAUTH_CLIENT_SECRET}&per_page=100", cb

  get_items: (url, cb) ->
    opts =
      headers:
        "User-Agent": "github.com/ddollar/godist"
    request.get url, opts, (err, res, body) =>
      return cb(err) if err
      items = JSON.parse(body)
      return cb(null, items) unless res.headers.link
      return cb(null, items) unless next = parse_links(res.headers.link).next
      @get_items next, (err, i) ->
        cb null, items.concat(i)

  post: (path, body, cb) ->
    request.post "https://api.github.com#{path}?access_token=#{@token}", body:JSON.stringify(body), (err, res, body) ->
      return cb(err) if err
      cb null, JSON.parse(body)

  delete: (path, cb) ->
    request.del "https://api.github.com#{path}?access_token=#{@token}", (err, res, body) ->
      return cb(err) if err
      cb null, body

exports.init = (args...) ->
  new Github(args...)
