_     = require 'underscore'
async = require 'async'
fs    = require 'fs'
redis = require 'redis'

client = null

@fileCache = {}

{extname, join, normalize} = require 'path'

exports.compilers = compilers =
  js: (module, filename) ->
    content = fs.readFileSync filename, 'utf8'
    module._compile content, filename

try
  CoffeeScript = require 'coffee-script'
  compilers.coffee = (module, filename) ->
    content = CoffeeScript.compile fs.readFileSync filename, 'utf8'
    module._compile content, filename
catch err

try
  eco = require 'eco'
  if eco.precompile
    compilers.eco = (module, filename) ->
      content = eco.precompile fs.readFileSync filename, 'utf8'
      module._compile "module.exports = #{content}", filename
  else
    compilers.eco = (module, filename) ->
      content = eco.compile fs.readFileSync filename, 'utf8'
      module._compile content, filename
catch err


exports.Package = class Package
  constructor: (config) ->
    @identifier   = config.identifier ? 'require'
    @paths        = config.paths ? ['lib']
    @dependencies = config.dependencies ? []
    @compilers    = _.extend {}, compilers, config.compilers

    @cache        = config.cache ? true
    @mtimeCache   = {}
    @compileCache = {}
    @sourceMap    = []

  compile: (callback) ->
    console.time 'compile files'

    client = redis.createClient()

    client.on 'error', (err) ->
      client.closing = true
      client.end()

    async.parallel [
      @compileDependencies
      @compileSources
    ], (err, parts) =>
      if err
        callback err
      else
        console.timeEnd 'compile files'

        if client.connected
          client.quit()

        callback null, parts.join("\n"), @sourceMap

  compileDependencies: (callback) =>
    async.map @dependencies, @compileFile, (err, dependencySources) =>
      if err then callback err
      else callback null, dependencySources.join("\n")

  compileSources: (callback) =>

    @sourceMap = []

    # console.warn { @paths }

    async.reduce @paths, {}, _.bind(@gatherSourcesFromPath, @), (err, sources) =>
      return callback err if err

      result = """
        (function(/*! Stitch !*/) {
          if (!this.#{@identifier}) {
            var modules = {};
            var registry = {};
            var cache = {}, require = function(name, root, skipRedefine) {

              if (skipRedefine == null) {
                skipRedefine = false;
              }

              var path = expand(root, name)

              if (! skipRedefine) {
                if (redefinedPath = registry[path]) {
                  path = redefinedPath;
                }
              }

              var altPath = expand(path, './index');

              var module = cache[path], altModule = cache[altPath], fn;
              if (module) {
                return module.exports;
              }
              else if (altModule){
                return altModule.exports
              } else if (fn = modules[path] || modules[path = altPath]) {
                module = {id: path, exports: {}};
                try {
                  cache[path] = module;
                  fn(module.exports, function(name, skipRedefine) {
                    return require(name, dirname(path), skipRedefine);
                  }, module);
                  return module.exports;
                } catch (err) {
                  delete cache[path];
                  throw err;
                }
              } else {
                throw 'module \\'' + name + '\\' not found';
              }
            }, expand = function(root, name) {
              var results = [], parts, part;
              if (/^\\.\\.?(\\/|$)/.test(name)) {
                parts = [root, name].join('/').split('/');
              } else {
                parts = name.split('/');
              }
              for (var i = 0, length = parts.length; i < length; i++) {
                part = parts[i];
                if (part == '..') {
                  results.pop();
                } else if (part != '.' && part != '') {
                  results.push(part);
                }
              }
              return results.join('/');
            }, dirname = function(path) {
              return path.split('/').slice(0, -1).join('/');
            };
            this.#{@identifier} = function(name) {
              return require(name, '');
            };
            this.#{@identifier}.define = function(bundle) {
              for (var key in bundle)
                modules[key] = bundle[key];
            };
            this.#{@identifier}.register = function(bundle) {
              for (var key in bundle)
                registry[key] = bundle[key];
            };
            this.#{@identifier}.modules = modules;
            this.#{@identifier}.registry = registry;
          }
          return this.#{@identifier}.define;
        }).call(this)({
      """

      index = 0
      for name, {filename, source, path} of sources
        result += if index++ is 0 then "" else ", "
        result += JSON.stringify name
        result += ": function(exports, require, module) {#{source}}"

        if path
          @sourceMap.push [name, path]

      result += """
        });\n
      """

      callback err, result

  createServer: ->
    (req, res, next) =>
      @compile (err, source) ->
        if err
          console.error "#{err.stack}"
          message = "" + err.stack
          res.writeHead 500, 'Content-Type': 'text/javascript'
          res.end "throw #{JSON.stringify(message)}"
        else
          res.writeHead 200, 'Content-Type': 'text/javascript'
          res.end source


  gatherSourcesFromPath: (sources, sourcePath, callback) ->

    fs.stat sourcePath, (err, stat) =>
      return callback err if err

      if stat.isDirectory()
        @getFilesInTree sourcePath, (err, paths) =>
          return callback err if err
          async.reduce paths, sources, _.bind(@gatherCompilableSource, @), callback
      else
        @gatherCompilableSource sources, sourcePath, callback

  gatherCompilableSource: (sources, path, callback) ->

    # console.log 'gather compilable', sources

    if @compilers[extname(path).slice(1)]
      @getRelativePath path, (err, relativePath) =>
        return callback err if err

        @compileFile path, (err, source) ->
          if err then callback err
          else
            extension = extname relativePath
            key       = relativePath.slice(0, -extension.length)
            sources[key] =
              filename: relativePath
              source:   source
              path: path
            callback err, sources
    else
      callback null, sources

  getRelativePath: (path, callback) ->
    fs.realpath path, (err, sourcePath) =>
      return callback err if err

      async.map @paths, fs.realpath, (err, expandedPaths) ->
        return callback err if err

        for expandedPath in expandedPaths
          base = expandedPath + "/"
          if sourcePath.indexOf(base) is 0
            return callback null, sourcePath.slice base.length
        callback new Error "#{path} isn't in the require path"

  compileFile: (path, callback) =>
    extension = extname(path).slice(1)
    cacheKey = "stitch-cache-#{path}"

    compileUnlessCached = (err, reply) =>

      if (! err) and reply and @mtimeCache[path] is reply.mtime
        callback null, reply.source

      else if compile = @compilers[extension]
        source = null
        mod =
          _compile: (content, filename) ->
            source = content

        try
          compile mod, path

          if mtime = @mtimeCache[path]

            if client?.connected

              client.hmset cacheKey, 'mtime', mtime, 'source', source, ->
                callback null, source

            else
              callback null, source

          else
            callback null, source

        catch err
          if err instanceof Error
            err.message = "can't compile #{path}\n#{err.message}"
          else
            err = new Error "can't compile #{path}\n#{err}"
          callback err

      else
        callback new Error "no compiler for '.#{extension}' files"

    if client?.connected
      client.hgetall cacheKey, compileUnlessCached

    else
      compileUnlessCached()

  walkTree: (directory, callback) ->

    fs.readdir directory, (err, files) =>
      return callback err if err

      async.forEach files, (file, next) =>
        return next() if file.match /^\./
        filename = join directory, file

        fs.stat filename, (err, stats) =>
          @mtimeCache[filename] = stats?.mtime?.toString()

          if !err and stats.isDirectory()
            @walkTree filename, (err, filename) ->
              if filename
                callback err, filename
              else
                next()
          else
            callback err, filename
            next()
      , callback

  getFilesInTree: (directory, callback) ->
    files = []
    # console.warn 'get files in tree', directory
    @walkTree directory, (err, filename) ->
      if err
        callback err
      else if filename
        files.push filename
      else
        callback err, files.sort()


exports.createPackage = (config) ->
  new Package config
