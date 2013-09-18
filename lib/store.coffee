coffee = require("coffee-script")
cradle = require("cradle")
url    = require("url")
uuid   = require("node-uuid")

class Store

  constructor: (@store_url) ->
    u = url.parse(store_url)
    a = (u.auth ? "").split(":")
    options =
      cache: false
      raw:   false
    if u.auth
      a = u.auth.split(":")
      options.auth =
        username: a[0]
        password: a[1]
    @couch = new(cradle.Connection) "#{u.protocol}//#{u.hostname}", (u.port ? 443), options
    @db = @couch.database((u.path ? "/store").slice(1))
    @initialize_couch() if process.env.COUCHDB_MASTER is "true"

  initialize_couch: ->
    @db.create (err) =>
      @db.save "_design/project",
        views:
          all:
            map: (doc) -> emit doc._id, null if doc.type is "project"
          by_repo:
            map: (doc) -> emit doc.repo if doc.type is "project"

  create: (type, attrs, cb) ->
    attrs.type = type
    @db.save uuid.v1(), attrs, (err, res) =>
      if err then cb(err) else @db.get(res.id, cb)

  fetch: (type, id, cb) ->
    @db.get id, (err, doc) ->
      return cb(err) if err
      return cb("invalid type") unless doc.type is type
      cb null, doc

  update: (type, id, changes, cb) ->
    @fetch type, id, (err, doc) =>
      @db.save id, coffee.helpers.merge(doc, changes), (err, res) =>
        if err then cb(err) else @db.get(id, cb)

  delete: (type, id, cb) ->
    @fetch type, id, (err, doc) =>
      @db.remove id, doc._rev, (err) ->
        cb err, doc

  list: (type, opts, cb) ->
    @view type, "all", opts, cb

  view: (type, view, opts, cb) ->
    if typeof(opts) is "function"
      cb = opts
      opts = {}
    options = coffee.helpers.merge(include_docs:true, opts)
    @db.view "#{type}/#{view}", options, (err, items) ->
      return cb(err) if err
      cb null, items.map (item) -> item

  changes: (type, cb) ->
    feed = @db.changes(filter:"#{type}/all", since:-1)
    feed.on "change", (change) => @db.get change.id, cb
    feed.on "error",  (err)    -> cb err

exports.init = (store_url) ->
  new Store(store_url)
