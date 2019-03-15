local conf   = dofile  '/etc/bbq.conf' -- load BBQ configuration
local yaml   = require 'yaml'
local colors = require 'ansicolors'
local path   = require 'pl.path'
local pldir  = require 'pl.dir'

local function msg (text, ...)
   print (string.format (colors (text), ...))
end


local function printf (format, ...)
   return (string.format (format, ...))
end


local function exec (cmd, ...)
   local command = string.format (cmd, ...)
   return os.execute (command)
end


local function die (...)
   msg (...)
   os.exit ()
end


-- Read the recipe, return Lua table containing it

local function readRc (pkg)
   local file, errText = io.open (conf.wok .. pkg .. '/recipe.yaml')
   if not file then
      die ('Recipe for %{red bright}%s%{reset} absent in the wok:\n%s\n', pkg, errText)
   end
   yaml.configure ({load_numeric_scalars = false})
   return yaml.load (file:read ("*a"))
end


-- Make an empty dir, clean it if it not empty

local function emptyDir (d)
   if path.exists (d) then
      assert (pldir.rmtree (d))
   end
   assert (pldir.makepath (d))
end


-- Check if string ends with some pattern

function string:ends (...)
   for _,i in ipairs ({...}) do
      local pattern = i:gsub ('%.', '%%.') .. '$' -- escape dots
      if self:match (pattern) then return true end
   end
   return false
end


-- Extract file to dir

local function extractFile (file, dir, opts)
   local app, cmd

   if file:ends ('.tar.gz', '.tgz',                   -- busybox tar
      '.tar.bz2', '.tar.bz', '.tbz2', '.tbz', 'tb2',
      '.tar.xz', '.txz',
      '.tar.lzma',
      '.tar.Z', '.tar.z', '.taz',
      '.tar') then
      cmd = printf ('tar -xf %s -C %s', file, dir)

   elseif file:ends ('.tlz') then -- both LZMA (.tar.lzma) and Lzip (.tar.lz) pretends for .tlz
      local hand  = io.open (file, 'rb')
      local magic = hand:read (4) -- read 4 bytes
      hand:close ()
      if magic == 'LZIP' then
         app = 'lzip'
         cmd = printf ('lzip -dcq %s | tar -xf - -C %s', file, dir)
      else
         cmd = printf ('tar -xf %s -C %s', file, dir)
      end

   elseif file:ends ('.lz') then
      app = 'lzip'
      if file:ends ('.tar.lz') then
         cmd = printf ('lzip -dcq %s | tar -xf - -C %s', file, dir)
      elseif file:ends ('.cpio.lz') then
         cmd = printf ('cd %s; lzip -dcq %s | cpio -idm --quiet', dir, file)
      else
         cmd = printf ('cd %s; lzip -dcq %s', dir, file)
      end

   elseif file:ends ('.zip', '.xpi') then
      cmd = printf ('unzip -qo %s -d %s', file, dir) -- busybox

   elseif file:ends ('.xz') then -- not .tar.xz
      if file:ends ('.cpio.xz') then
         cmd = printf ('cd %s; unxz -ck %s | cpio -idm --quiet', dir, file)
      else
         cmd = printf ('cd %s; unxz -k %s', dir, file)
      end

   elseif file:ends ('.7z') then
      app = 'p7zip'
      cmd = printf ('cd %s; 7zr x %s', dir, file)

   elseif file:ends ('.rpm') then
      cmd = printf ('cd %s; rpm2cpio %s | cpio -idm --quiet', dir, file)

   elseif file:ends ('.run') then
      cmd = printf ('cd %s; /bin/sh %s %s', dir, file, (opts or ''))

   else
      cmd = printf ('cp %s %s', file, dir)
   end

   if app then print ('install "'..app..'"') end

   emptyDir (dir)
   msg ('%{yellow}'..cmd)
   assert (os.execute (cmd))
end


-- Compress dir to file; used to recompress VCS (Hg, Git, ...) sources,
-- so no rare formats here

local function comressDir (dir, file)
   local cmd

   if file:ends ('.tar.gz', '.tgz') then
      cmd = printf ('tar -czf %s -C %s *', file, dir)

   elseif file:ends ('.tar.bz2', '.tar.bz', '.tbz2', '.tbz', '.tb2') then
      cmd = printf ('tar -cjf %s -C %s *', file, dir)

   elseif file:ends ('.tar.xz', '.txz') then
      cmd = printf ('tar -cJf %s -C %s *', file, dir)

   elseif file:ends ('.tar.lzma', '.tlz') then
      cmd = printf ('tar -caf %s -C %s *', file, dir)

   elseif file:ends ('.tar.Z', '.tar.z', '.taz') then
      cmd = printf ('tar -cZf %s -C %s *', file, dir)

   elseif file:ends ('.tar') then
      cmd = printf ('tar -cf %s -C %s *', file, dir)

   elseif file:ends ('.cpio.gz') then
      cmd = printf ('cd %s; find . | cpio -o -H newc --quiet | gzip -c > %s', dir, file)

   elseif file:ends ('.cpio.bz2', '.cpio.bz') then
      cmd = printf ('cd %s; find . | cpio -o -H newc --quiet | bzip2 -c > %s', dir, file)

   elseif file:ends ('.cpio.xz') then
      cmd = printf ('cd %s; find . | cpio -o -H newc --quiet | xz -qzeT0 > %s', dir, file)

   end

   msg ('%{yellow}'..cmd)
   assert (os.execute (cmd))
end

-- .tar.gz   .tbz   .tar.bz2   .tar.xz   .zip   .tar.lzma   .gem   .tar.lz   .tbz2
-- .deb .rpm .tar   .xz   .gz   .xpi   .bz2   .7z   .cpio


local function applyPlaceholders (rc)
   -- hiversion: high X.Y version
   rc.hiversion = rc.version:gsub ('(%d+%.%d+).*', '%1')

   -- subversion: substituted version
   if rc.subversion then
      if type (rc.subversion) == 'table' then
         -- substitute function arguments: [from, to]
         rc.sversion = rc.version:gsub(rc.subversion[1], rc.subversion[2])
      elseif type (rc.subversion) == 'string' then
         -- exact value
         rc.sversion = rc.subversion
      else
         die ('Unknown type for "subversion": %s', type (rc.subversion))
      end
   end

   local function ph (value)
      return value
         :gsub('<o>', rc.origin or '')            -- '$o' is placeholder for origin
         :gsub('<n>', rc.name)                    -- '$n' - for name
         :gsub('<v>', rc.version)                 -- '$v' - for version
         :gsub('<V>', rc.hiversion)               -- '$V' - for X.Y hi-version (GNOME)
         :gsub('<s>', rc.sversion or '')
         :gsub('<w>', rc.home)
   end

   if rc.src then
      for i in ipairs (rc.src) do
         -- default file for VCS is like 'nano-git.tar.gz'
         if rc.src[i].app then
            if not rc.src[i].file then
               rc.src[i].file = rc.name .. '-' .. rc.src[i].app .. '.tar.gz'
            end
            rc.src[i].vcsdir = rc.name .. '-' .. rc.src[i].app
         end

         rc.src[i].url = ph (rc.src[i].url)

         -- apply pseudo-protocols in url
         for pseudoProto, subUrl in pairs (conf.mirrors) do
            rc.src[i].url = rc.src[i].url:gsub (pseudoProto, subUrl)
         end

         rc.src[i].file = ph (rc.src[i].file or rc.src[i].url:gsub('.*/', ''))   -- basename by default
      end
   end

   if rc.prepare.patches then
      for i in ipairs (rc.prepare.patches) do
         if rc.prepare.patches[i].name then
            rc.prepare.patches[i].name = ph (rc.prepare.patches[i].name)
         end
         if rc.prepare.patches[i].url then
            rc.prepare.patches[i].url = ph (rc.prepare.patches[i].url)
            -- apply pseudo-protocols in url
            for pseudoProto, subUrl in pairs (conf.mirrors) do
               rc.prepare.patches[i].url = rc.prepare.patches[i].url:gsub (pseudoProto, subUrl)
            end
         end
      end
   end

   return rc
end





return {
   msg         = msg,
   printf      = printf,
   exec        = exec,
   die         = die,
   readRc      = readRc,
   emptyDir    = emptyDir,
   extractFile = extractFile,
   comressDir  = comressDir,
   applyPlaceholders = applyPlaceholders
}
