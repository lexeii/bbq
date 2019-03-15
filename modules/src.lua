--[[
   Prepare the sources to be compiled.
   -- Using:
      src = require 'bbq.src'

   -- Define data structure using YAML recipe.
   -- 'src' may contain definitions for multiple sources; fields here:
   -- url  (mandatory)
   --      allows placeholders: $n - for name value; $v - version...
   --      allow schemes: https://, http://, ftp://
   --      allow pseudo-schemes: gnu:// (GNU mirror), sf:// (SourceForge mirror)...
   -- file (optional)
   --      if you don't want to store source tarball to the sources cache
   --      with it's original name, you may define store name here
   -- sha1 (optional)
   --      checksums allowed: md5, sha1, sha3, sha256, sha512
   -- dir  (optional)
   --      chances you want to extract secondary sources not just to $src but
   --      into some specified sub-dir

      origin : yaml
      name   : lua-yaml
      version: 1.1.2
      src:
      - url:  https://github.com/lubyk/$o/archive/REL-$v.tar.gz
        file: $n-$v.tar.gz
        sha1: e455ec834a0be4998b7be0d6b292fa169cbe7f89
      - url:  http://example.com/tarball.tar.gz
        md5:  d41d8cd98f00b204e9800998ecf8427e
        dir:  example

   -- Use the function: download if not yet downloaded, check integrity
   -- if checksums provided and extract sources:
      src.get(pkg)
]]


--[[
https://github.com/mpx/lua-cjson/archive/2.1.0.tar.gz
https://codeload.github.com/mpx/lua-cjson/tar.gz/2.1.0
Content-Disposition: attachment; filename=lua-cjson-2.1.0.tar.gz

https://api.github.com/repos/mpx/lua-cjson/tarball/2.1.0
https://codeload.github.com/mpx/lua-cjson/legacy.tar.gz/2.1.0
Content-Disposition: attachment; filename=mpx-lua-cjson-2.1.0-0-g4bc5e91.tar.gz
--]]

local conf   = dofile  '/etc/bbq.conf' -- load BBQ configuration
local lib    = require 'bbq.lib'
local pldir  = require 'pl.dir'
local printf = lib.printf




local function extractVcs (src)
   local tmpdir = conf.src .. src.vcsdir
   lib.emptyDir (tmpdir)
   lib.extractFile (conf.src .. src.file, tmpdir)
end


local function fetchUrl (src)
   local hand, mode


   hand = io.open (conf.src .. src.file)
   if hand then mode = 'update' else mode = 'new' end

   lib.msg('%{blue}>url="%s"\n>app="%s"\n>mode="%s"', src.url, src.app or '', mode)

   if not src.app then
      src.app = 'wget'
      if mode == 'new' then
         lib.exec ('wget -q -O %s %s', conf.src..src.file, src.url)
      else
         lib.msg ('%{green}Ok, file already downloaded.')
      end

   elseif src.app == 'hg' then
      lib.emptyDir (conf.src .. src.vcsdir)
      if mode == 'new' then
         lib.exec ('hg clone %s %s', src.url, src.vcsdir)
      else
         extractVcs (src)
         lib.exec ('cd %s; hg pull -u', src.vcsdir)
      end
      -- switch to the branch, need to `hg update` to finish the switching
      if src.branch then lib.exec ('hg branch %s', src.branch) end
      -- switch to the revision
      if src.rev then
         lib.exec ('hg update -r %s', src.rev)
      else
         lib.exec ('hg update')
      end

   elseif src.app == 'git' then
      src.app = 'git'
      if mode == 'new' then
         lib.exec ('git clone %s $pkgsrc', src.url)
         if src.branch then lib.exec ('cd $pkgsrc; git checkout %s; cd ..', src.branch) end
      else
         lib.msg('???')
      end

   elseif src.app == 'svn' then
      if mode == 'new' then
         if src.rev then lib.exec ('echo t | svn co %s -r %s $pkgsrc', src.url, src.rev)
         else            lib.exec ('echo t | svn co %s $pkgsrc', src.url)
         end
      else
         lib.msg('???')
      end

   elseif src.app == 'bzr' then
      if mode == 'new' then
         if src.rev then lib.exec ('bzr -Ossl.cert_reqs=none branch %s -r %s', src.url, src.rev)
         else            lib.exec ('bzr -Ossl.cert_reqs=none branch %s', src.url)
         end
      else
         lib.msg('???')
      end

   else
      lib.msg ('%{red}Unrecognized application and/or protocol "%s"', src.proto)
   end

   -- check existence
   hand = io.open (conf.src .. src.file)
   return hand
end




local function checkIntegrity (src)
   local stream, givenSum
   local cmd = {
      md5    = 'busybox md5sum',    sha1   = 'busybox sha1sum',
      sha3   = 'busybox sha3sum',   sha256 = 'busybox sha256sum',
      sha512 = 'busybox sha512sum', b2     = 'b2sum',
      b2b    = 'b2sum -a blake2b',  b2s    = 'b2sum -a blake2s',
      b2bp   = 'b2sum -a blake2bp', b2sp   = 'b2sum -a blake2sp'
   }

   for _, sum in ipairs {'md5', 'sha1', 'sha3', 'sha256', 'sha512', 'b2', 'b2b', 'b2s', 'b2bp', 'b2sp'} do
      if src[sum] then
         io.write (printf('Checking %9s of %s: ', sum..'sum', src.file))

         stream = io.popen (cmd[sum]..' '..conf.src..src.file)
         givenSum = stream:read():gsub('%s.+', '')

         if givenSum == src[sum] then
            lib.msg ('%{green}Ok')
         else
            lib.msg ('%{red}Failed')
            return false -- fail immediately
         end
      end
   end
   return true -- all the checksums are Ok
end



-- Get all the sources for specified package

local function get (pkg)
   local rc, file, hand, srcdir1, srcdir2, tmpdir, ok
   rc = lib.readRc (pkg)

   -- hiversion: high X.Y version
   rc.hiversion = rc.version:gsub ('(%d+%.%d+).*', '%1')

   -- subversion: substituted version, for example, to change from '.' to '_':
   -- { '%.', '_' }
   if rc.subversion then
      if type (rc.subversion) == 'table' then
         rc.sversion = rc.version:gsub(rc.subversion[1], rc.subversion[2])
      elseif type (rc.subversion) == 'string' then
         rc.sversion = rc.subversion
      else
         lib.die ('Unknown type for "subversion": %s', type (rc.subversion))
      end
   end

   -- remove prevous src (if any)
   srcdir1 = conf.wok .. pkg .. '/src/'
   lib.emptyDir (srcdir1)

   for i in ipairs(rc.src) do

      -- default file for VCS is like nano-git.tar.gz
      if rc.src[i].app then
         if not rc.src[i].file then
            rc.src[i].file = rc.name .. '-' .. rc.src[i].app .. '.tar.gz'
         end
         rc.src[i].vcsdir = rc.name .. '-' .. rc.src[i].app
      end

      -- apply substitutions
      rc.src[i].url = rc.src[i].url
         :gsub('<o>', rc.origin or '')            -- '$o' is placeholder for origin
         :gsub('<n>', rc.name)                    -- '$n' - for name
         :gsub('<v>', rc.version)                 -- '$v' - for version
         :gsub('<V>', rc.hiversion)               -- '$V' - for X.Y hi-version (GNOME)
         :gsub('<s>', rc.sversion or '')
      for pseudoProto, subUrl in pairs (conf.mirrors) do
         rc.src[i].url = rc.src[i].url:gsub (pseudoProto, subUrl)
      end
      rc.src[i].file = (rc.src[i].file or rc.src[i].url:gsub('.*/', ''))   -- basename by default
         :gsub('<o>', rc.origin or '')
         :gsub('<n>', rc.name)
         :gsub('<v>', rc.version)
         :gsub('<V>', rc.hiversion)
         :gsub('<s>', rc.sversion or '')

      -- get source
      hand = fetchUrl (rc.src[i])
      if not hand then
         lib.die ("%{red}Can't get src[%d] from %s using %s", i, rc.src[i].url, rc.src[i].app)
      end


      -- check file integrity
      ok = checkIntegrity (rc.src[i])
      if not ok then return nil end


      -- Make tarball
      -- tarball="$pkgsrc.tar.bz2"
      -- _ 'Creating tarball "%s"' "$tarball"
      -- tar -cjf $tarball $pkgsrc || exit 1
      -- mv $tarball $SRC
      -- rm -rf $pkgsrc

      -- prepare place
      --srcdir2 = srcdir1 .. pkg .. '-' .. rc.version .. '/'

      file = conf.src .. rc.src[i].file
      tmpdir = conf.wok .. pkg .. '/tmp/'
      lib.extractFile (file, tmpdir, rc.src[i].opts)

      -- remove outer dir(s) until we reach files or dirs
      repeat
         local tmpFiles = pldir.getfiles       (tmpdir)
         local tmpDirs  = pldir.getdirectories (tmpdir)
         if #tmpFiles == 0 and #tmpDirs == 1 then  -- if we have only one dir and no files here
            assert (os.execute (printf ('mv %s/* %s', tmpDirs[1], tmpdir))) -- move content of outer dir
            assert (os.execute (printf ('rm -r %s',   tmpDirs[1]))) -- and remove now-empty outer dir
            tmpFiles = pldir.getfiles (tmpdir)
            for n,v in ipairs (tmpFiles) do
               lib.msg ('%2s. %s', n, v)
            end
            tmpDirs  = pldir.getdirectories (tmpdir)
            for n,v in ipairs (tmpDirs) do
               lib.msg ('%2s. %s/', n, v)
            end
         end
      until #tmpFiles ~= 0 or #tmpDirs >= 1

      -- extract to specified directory
      if rc.src[i].dir then
         srcdir2 = srcdir1 .. '/' .. rc.src[i].dir
         assert (os.execute (printf ('mkdir -p %s', srcdir2)))
      else
         srcdir2 = srcdir1
      end

      assert (os.execute (printf ('cp -r %s* %s', tmpdir, srcdir2)))
      assert (os.execute (printf ('rm -r %s', tmpdir)))
      print ('')
   end
end

return {
   get = get
}
