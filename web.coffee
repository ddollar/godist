async    = require("async")
coffee   = require("coffee-script")
dd       = require("./lib/dd")
escape   = require("shell-escape")
express  = require("express")
fs       = require("fs")
github   = require("./lib/github")
log      = require("./lib/logger").init("godist")
mktmpdir = require("mktmpdir")
request  = require("request")
semver   = require("semver")
spawner  = require("./lib/spawner").init()
stdweb   = require("./lib/stdweb")
store    = require("./lib/store").init("#{process.env.COUCHDB_URL}/godist")
storage  = require("./lib/storage").init()

platforms = process.env.PLATFORMS.split(" ")

oauth = require("github-oauth")
  githubClient: process.env.OAUTH_CLIENT_ID
  githubSecret: process.env.OAUTH_CLIENT_SECRET
  baseURL:      process.env.BASE_URL
  loginURI:     "/auth"
  callbackURI:  "/auth/callback"
  scope:        "public_repo"

auth_required = (req, res, next) ->
  if req.cookies.token then next() else res.redirect "/auth"

app = stdweb("godist")

app.use express.static("#{__dirname}/public")
app.use (req, res, next) ->
  req.github = github.init(req.cookies.token) if req.cookies.token
  res.locals.navigation = (name, path) ->
    klass = if req.path is path then "active" else ""
    "<li class=\"#{klass}\"><a href=\"#{path}\">#{name}</a></li>"
  res.locals.hook_enabled = (project) ->
    for hook in project.hooks
      return true if hook.config.url is "#{process.env.BASE_URL}/push/#{project._id}"
    false
  res.locals.current_version = (project) ->
    project.versions[project.versions.length-1] || "none"
  res.locals.platforms = platforms
  res.locals.format_bytes = (bytes, label) ->
    num = parseInt(Math.floor(Math.log(bytes) / Math.log(1024*1024)))
    total = Math.round(bytes * 100 / (1024 * 1024)) / 100
    parseFloat(total).toFixed(2).toString()
  next()
app.use (req, res, next) ->
  if req.cookies.token
    req.github.get "/user", (err, user) ->
      req.user = user
      next()
  else
    next()
app.use app.router

app.get "/", auth_required, (req, res) ->
  res.redirect "/projects"

app.get "/projects", auth_required, (req, res) ->
  req.github.get "/user/repos", (err, repos) ->
    req.github.get "/user/orgs", (err, orgs) ->
      async.each orgs, ((org, cb) ->
        req.github.get "/orgs/#{org.login}/repos?type=member", (err, org_repos) ->
          repos = repos.concat(org_repos)
          cb null),
        (err) ->
          repos.sort (a, b) ->
            a.full_name.localeCompare(b.full_name)
          repo_names = repos.map (repo) -> repo.full_name
          store.list "project", (err, projects) ->
            projects = projects.filter (project) -> repo_names.indexOf(project.repo) > -1
            async.map projects, ((project, cb) ->
              req.github.get "/repos/#{project.repo}/hooks", (err, hooks) ->
                project.hooks = hooks
                cb null, project),
            (err, projects) ->
              res.render "projects.jade", projects:projects, repos:repos

app.get "/projects/:id/releases/:version", (req, res) ->
  version = req.params.version
  store.fetch "project", req.params.id, (err, project) ->
    async.reduce platforms, {}, ((ax, platform, cb) ->
      storage.head "/#{project.repo}/#{version}/#{platform.replace('/','-')}", (err, head) ->
        ax[platform] = head
        cb err, ax),
    (err, heads) ->
      console.log "err", err
      console.log "heads", heads
      res.render "version.jade", project:project, version:version, heads:heads

app.post "/projects", auth_required, (req, res) ->
  store.view "project", "by_repo", startkey:req.body.repo, endkey:req.body.repo, (err, existing) ->
    if existing.length is 0
      store.create "project", repo:req.body.repo, versions:[], (err, project) ->
        res.redirect "/projects"
    else
      res.redirect "/projects"

app.post "/projects/:id/hook", auth_required, (req, res) ->
  store.fetch "project", req.params.id, (err, project) ->
    hook =
      name:   "web"
      active: true
      events: [ "push" ]
      config:
        url: "#{process.env.BASE_URL}/push/#{project._id}"
        content_type: "json"
    req.github.post "/repos/#{project.repo}/hooks", hook, (err, hook) ->
      res.redirect "/projects"

app.post "/projects/:id/unhook", auth_required, (req, res) ->
  store.fetch "project", req.params.id, (err, project) ->
    req.github.get "/repos/#{project.repo}/hooks", (err, hooks) ->
      async.each hooks, ((hook, cb) ->
        if hook.config.url is "#{process.env.BASE_URL}/push/#{project._id}"
          req.github.delete "/repos/#{project.repo}/hooks/#{hook.id}", cb
        else
          cb null),
      (err) ->
        res.redirect "/projects"

app.post "/projects/:id/releases/:version/:os-:arch/rebuild", (req, res) ->
  platform = "#{req.params.os}/#{req.params.arch}"
  store.fetch "project", req.params.id, (err, project) ->
    console.log "building: #{platform}"
    binary = ""
    reader = request.get("https://gobuild.herokuapp.com/#{project.repo}/v#{req.params.version}/#{platform}")
    reader.on "data", (data) ->
      binary += data.toString("binary")
    reader.on "end", ->
      console.log "build complete: #{platform}"
      console.log "uploading: #{platform}"
      storage.create "/#{project.repo}/#{req.params.version}/#{platform.replace("/","-")}", binary, (err) ->
        console.log "upload finished: #{platform}"
        res.redirect "/projects/#{req.params.id}/releases/#{req.params.version}"

app.post "/push/:id", (req, res) ->
  store.fetch "project", req.params.id, (err, project) ->
    if match = /^refs\/tags\/(.*)$/.exec(req.body.ref)
      version = ref = match[1]
      version = version.substring(1) if version[0] is "v"
      for existing in project.versions
        return res.send("invalid version", 403) if semver.gte(existing, version)
      res.send "ok"
      async.eachSeries platforms, ((platform, cb) ->
        console.log "building: #{platform}"
        store.fetch "project", project._id, (err, project) ->
          binary = ""
          reader = request.get("https://gobuild.herokuapp.com/#{project.repo}/#{ref}/#{platform}")
          reader.on "data", (data) ->
            binary += data.toString("binary")
          reader.on "end", ->
            console.log "build complete: #{platform}"
            console.log "uploading: #{platform}"
            storage.create "/#{project.repo}/#{version}/#{platform.replace("/","-")}", binary, (err, res) ->
              console.log "upload finished: #{platform}"
              cb err),
      (err) ->
        project.versions.push(version)
        store.update "project", project._id, versions:project.versions, (err, project) ->
          console.log "builds complete"

app.get "/projects/:user/:repo/releases/:version/:os-:arch/:name.:type?", (req, res) ->
  repo = "#{req.params.user}/#{req.params.repo}"
  store.view "project", "by_repo", startkey:repo, endkey:repo, (err, existing) ->
    return res.send("no such release", 403) unless existing.length is 1
    project = existing[0]
    version = req.params.version
    version = project.versions[project.versions.length-1] if version is "current"
    filename = "#{repo}/#{version}/#{req.params.os}-#{req.params.arch}"
    storage.exists filename, (err, exists) ->
      return res.send("no such release", 403) unless exists
      storage.get filename, (err, get) -> get.pipe(res)

app.get "/projects/:user/:repo/diff/:from/:to/:os-:arch", (req, res) ->
  repo = "#{req.params.user}/#{req.params.repo}"
  store.view "project", "by_repo", startkey:repo, endkey:repo, (err, existing) ->
    return res.send("no such release", 403) unless existing.length is 1
    project = existing[0]
    from = req.params.from
    to = req.params.to
    return res.send("no such from", 403) unless project.versions.indexOf(from) > -1
    return res.send("no such to", 403) unless project.versions.indexOf(to) > -1
    filename = "#{repo}/#{from}-#{to}/#{req.params.os}-#{req.params.arch}"
    storage.exists filename, (err, exists) ->
      if exists
        storage.get filename, (err, get) -> get.pipe(res)
      else
        mktmpdir (err, dir) ->
          async.parallel
            from: (cb) ->
              fd = fs.createWriteStream("#{dir}/from")
              storage.get "#{repo}/#{from}/#{req.params.os}-#{req.params.arch}", (err, get) ->
                get.pipe(fd)
                get.on "end", -> cb null, "#{dir}/from"
            to: (cb) ->
              fd = fs.createWriteStream("#{dir}/to")
              storage.get "#{repo}/#{to}/#{req.params.os}-#{req.params.arch}", (err, get) ->
                get.pipe(fd)
                get.on "end", -> cb null, "#{dir}/to"
            (err, results) ->
              mktmpdir (err, dir) ->
                ps = spawner.spawn "vendor/bin/bsdiff #{escape([results.from, results.to])} #{dir}/patch", env:{}
                ps.on "end", ->
                  fs.stat "#{dir}/patch", (err, stat) ->
                    fd = fs.createReadStream("#{dir}/patch")
                    fd.on "open", ->
                      storage.create_stream filename, fd, stat.size, (err) -> console.log "s3err", err
                      fd.pipe(res)

app.get "/projects/:user/:repo/releases/:os-:arch", (req, res) ->
  repo = "#{req.params.user}/#{req.params.repo}"
  store.view "project", "by_repo", startkey:repo, endkey:repo, (err, existing) ->
    return res.send("error", 403) if err
    return res.send("no such project", 403) unless existing.length is 1
    project = existing[0]
    async.map project.versions.reverse(), ((version, cb) ->
      cb null
        version: version
        url: "#{process.env.BASE_URL}/projects/#{repo}/releases/#{version}/#{req.params.os}-#{req.params.arch}/#{req.params.repo}"),
    (err, releases) ->
      return res.send("error fetching releases", 403) if err
      res.send JSON.stringify(releases)

oauth.addRoutes app, (err, token, res) ->
  return res.send("invalid auth", 403) if err
  res.cookie "token", token.access_token
  res.redirect "/"

app.start (port) ->
  console.log "listening on #{port}"
