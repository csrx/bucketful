Q = require 'q'
_ = require 'underscore'
_s = require 'underscore.string'
opra = try require 'opra'
knox = require 'knox'
path = require 'path'
nconf = require 'nconf'
wrench = require 'wrench'
powerfs = require 'powerfs'
awssum = require 'awssum'
awssumHelpers = require './awssum-helpers'
AWS = require 'aws-sdk'
loopia = require 'loopia-api'
loopiaTools = require './loopia'

S3 = awssum.load('amazon/s3').S3

process.on 'uncaughtException', ->
  console.log arguments

qfilter = (list, callback) ->
  ps = list.map callback
  Q.all(ps).then (mask) ->
    list.filter (x, i) -> mask[i]

exports.deploy = (options) ->

  if !opra
    console.log("Could not find opra.")
    console.log("Install it using npm before using bucketful!")
    return

  nconf.overrides(options).argv()
  nconf.file "config", "config.json"
  nconf.file "package", "package.json"
  nconf.file "user", path.join(process.env.HOME, ".bucketful")

  nconf.env().defaults bucketful:
    html: ["index.html"]
    targetDir: path.join(process.cwd(), "public")
    include: []
    exclude: []
    websiteIndex: 'index.html'
    websiteError: 'index.html'

  s3bucket    = nconf.get 'bucketful:bucket'
  aws_key     = nconf.get 'bucketful:key'
  aws_secret  = nconf.get 'bucketful:secret'
  aws_user    = nconf.get 'bucketful:username'
  excludes    = nconf.get 'bucketful:exclude'
  includes    = nconf.get 'bucketful:include'
  region      = nconf.get 'bucketful:region'
  siteIndex   = nconf.get 'bucketful:websiteIndex'
  siteError   = nconf.get 'bucketful:websiteError'
  html        = nconf.get 'bucketful:html'
  opraOptions = nconf.get 'bucketful:opra'
  loopiaOpts  = nconf.get 'loopia'
  targetDir   = path.resolve nconf.get 'bucketful:targetDir'

  console.log ""
  console.log "STEP 1 - Loading settings"
  console.log "========================="
  console.log "Loaded the following options", nconf.get 'bucketful'
  console.log "Resolved targetDir", targetDir

  client = knox.createClient
    key: aws_key
    secret: aws_secret
    bucket: s3bucket
    endpoint: s3bucket + ".s3-external-3.amazonaws.com"

  s3 = new S3
    accessKeyId: aws_key
    secretAccessKey: aws_secret
    region: region

  AWS.config.update
    region: region
    accessKeyId: aws_key
    secretAccessKey: aws_secret
  awsSdkS3 = new AWS.S3()

  if loopiaOpts && loopiaOpts.username && loopiaOpts.password
    loopiaClient = loopia.createClient(loopiaOpts.username, loopiaOpts.password)

  opraBuild = Q.nbind(opra.build, opra)
  powerfsWriteFile = Q.nbind(powerfs.writeFile, powerfs)
  powerfsIsFile = Q.nbind(powerfs.isFile, powerfs)
  clientPutFile = Q.nbind(client.putFile, client)
  getBucketNames = Q.nbind(awssumHelpers.getBucketNames)
  createBucket = Q.nbind(awssumHelpers.createBucket)
  bucketToWebsite = Q.nbind(awssumHelpers.bucketToWebsite)
  giveEveryoneReadAccess = Q.nbind(awssumHelpers.giveEveryoneReadAccess)


  ## This functions handles the uploading of all static files (those not compiled by opra)
  uploadTrack = ->

    # Get the list of files as described by the "includes" argument
    Q.resolve().then ->
      files = []
      if includes.length > 0
        includes.forEach (file) ->
          fullpath = path.join(targetDir, file)
          if powerfs.isDirectorySync(fullpath)
            files = files.concat wrench.readdirSyncRecursive(fullpath).filter((f) -> f[0] != '.').map (f) -> path.join file, f
          else
            files.push file

      else
        files = wrench.readdirSyncRecursive(targetDir)
        files = files.filter (file) -> file.split('/').every (part) -> part[0] != '.' # exclude all hidden files

      files = files.map (x) -> { fullpath: path.join(targetDir, x), name: x }
      files

    # Exclude files based on the "excludes" argument
    .then (files) ->
      files.filter (file) ->
        excludes.every (x) ->
          file.name != x && !_s.startsWith(file.name, x + "/")

    # Exclude directories
    .then (files) ->
      qfilter files, (file) -> powerfsIsFile file.fullpath

    # Exclude opra-processed files
    .then (files) ->
      files.filter (file) -> !_(html).contains(file.name)

    # Upload the remaining files
    .then (files) ->
      console.log "Uploading #{files.length} static file(s)..."
      counter = 0

      Q.all files.map (file, i) ->
        clientPutFile(file.fullpath, "/" + file.name, { 'x-amz-acl': 'public-read' }).then ->
          counter++
          console.log "static [#{counter}/#{files.length}] #{file.name}"



  ## This functions manages the files that should be compiled by opra
  uploadOpraTrack = ->
    uploadCount = 0
    console.log "Uploading #{html.length} opra file(s)..."

    # for each html file
    Q.all html.map (file) ->

      clientPutFile("tmp/" + file, "/" + file, { 'x-amz-acl': 'public-read' })

      # print the completion message
      .then ->
        uploadCount++
        console.log "opra [#{uploadCount}/#{html.length}] Upload of #{file} completed"



  ## This functions manages the files that should be compiled by opra
  compileTrack = ->
    compileCount = 0
    console.log "Compiling #{html.length} opra file(s)..."

    # for each html file
    Q.all html.map (file) ->

      # run the opra builder
      opraBuild("public/#{file}", opraOptions)

      # write the file to disk
      .then (data) ->
        powerfsWriteFile "tmp/" + file, data, "utf8"
      .then ->
        compileCount++
        console.log "compiled [#{compileCount}/#{html.length}]"



  console.log ""
  console.log "STEP 2 - Locating bucket"
  console.log "========================"

  getBucketNames(s3).then (buckets) ->

    if _(buckets).contains(s3bucket)
      console.log "Success: Bucket found in the given account"
    else
      console.log "Warning: Bucket not found in the given account. Attempting to create it."
      aws_user = "signup@leanmachine.se"

      createBucket(awsSdkS3, { name: s3bucket, fullRightsUser: aws_user, key: aws_key, secret: aws_secret }).then ->
        console.log "Bucket created. Configuring it as a website."
        bucketToWebsite(awsSdkS3, { name: s3bucket, index: siteIndex, error: siteError })
      .then ->
        console.log "Setting READ access for everyone."
        giveEveryoneReadAccess(awsSdkS3, { name: s3bucket })
      .then ->
        console.log "Success: Bucket created!"

  .then ->
    if loopiaClient?
      console.log "setting up cname for bucket"
      cname = "#{s3bucket}.s3-website-#{region}.amazonaws.com"
      Q.nfcall(loopiaTools.putSubdomainCNAME, loopiaClient, s3bucket, cname)
  .then ->

    console.log ""
    console.log "STEP 3 - Accessing bucket"
    console.log "========================="

    # Run the main procedure
    req = client.put '/.handshake',
      'Content-Length': 6
      'Content-Type': 'text/plain'

    req.on 'response', (res) ->
      if res.statusCode != 200
        console.log("Failed with status code", res.statusCode)
      else
        console.log "Success: Upload access secured"

        console.log ""
        console.log "STEP 4 - Compilation"
        console.log "===================="

        compileTrack().then ->

          console.log ""
          console.log "STEP 5 - Upload"
          console.log "==============="

          uploadOpraTrack()
        .then ->
          uploadTrack()
        .then ->
          console.log "done"
          console.log ""
          console.log "STEP 6 - Keeping you up to speed"
          console.log "================================"
          console.log "Site now available on: http://#{s3bucket}.s3-website-#{region}.amazonaws.com"
          console.log "If your DNS has been configured correctly, it can also be found here: http://#{s3bucket}"
          console.log ""
          console.log "kthxbai"
        .fail (err) ->
          console.log ""
          console.log "FAILED MISERABLY!"
          console.log err
        .done()

    req.end('oh hai')
  .fail (err) ->
    console.log ""
    console.log "FAILED MISERABLY!"
    console.log err
  .done()
