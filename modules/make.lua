--[[

Construct the commands using the 'prepare', 'make' & 'post' branches of the recipe


Patch branch:

prepare:
  patches:
  # a) get patch from URL, check its integrity and save to the source cache:
  - url   : http://example.com/patch
    sha256: hash

  # b) use patch defined in the 'files' branch, don't need to check integrity
  #    because file is under your control:
  - name: file.patch

  # c) get patch from URL, check integrity and save to the source cache
  #    using the different name:
  - url : http://example.com/patch
    sha1: hash
    name: match.patch

When you use local files for patch [b) case], and for any local files,
each used file should be defined inside 'files' branch either by 'content'
multiline field or by 'link' to real file.

files:
# a) insert plain text file (only UTF-8 encoded with Unix line endings) inside the recipe:
- name: foo
  content: |
    ...

# b) insert binary file (or text file not matched the a) requirements) as base64 encoded:
- name: bar
  type: base64
  content: |
    ...

# c) provide relative path to the file (you may skip './' at the start):
- name: baz
  link: relative-path-to-baz

--]]

local conf = dofile  '/etc/bbq.conf' -- load BBQ configuration
local lib  = require 'bbq.lib'
local die  = lib.die




local function getPatchFromUrl (patch, dir)
   local hand

   if not patch.name then
      patch.name = patch.url:gsub('.*/', '') -- basename
   end

   hand = io.open (conf.src..patch.name)
   if not hand then
      lib.exec ('wget -O "%s" "%s"', conf.src..patch.name, patch.url)
      hand = io.open (conf.src..patch.name)
      if not hand then
         die ("\n%{red}ERROR: Can't get patch from \"%s\"", patch.url)
      end
   end
   if hand then hand:close() end

   lib.exec ('cp %s %s', conf.src..patch.name, dir)

   -- check file integrity
   patch.file = patch.name
   if not lib.checkIntegrity (patch) then
      die ("\n%{red}ERROR: Checksum doesn't match!")
   end
end




local function getFileFromRecipe (recipe, filename, dir)
   local index, file

   if not recipe.files then
      die ("\n%{red}ERROR: Can't get file \"%s\" from recipe (no files defined)", filename)
   else
      for i, j in ipairs (recipe.files) do
         if j.name == filename then
            index = i
         end
      end
      if not index then
         die ("\n%{red}ERROR: Can't get file \"%s\" from recipe (not defined)", filename)
      end
   end

   if recipe.files[index].link then
      lib.exec ('cd %s; cp %s %s',
         conf.wok .. recipe.name,
         './' .. recipe.files[index].link, dir..filename)

   elseif recipe.files[index].content then
      file = io.open (dir..'temp', 'w')
      file:write (recipe.files[index].content)
      file:close () -- or file will be partially saved

      if recipe.files[index].type then
         if recipe.files[index].type == 'base64' then
            lib.exec ('base64 -d %s > %s; rm %s', dir..'temp', dir..filename, dir..'temp')
         else
            die ('\n%{red}ERROR: Unknown type "%s" for file "%s"', recipe.files[index].type, recipe.files[index].name)
         end
      else
         lib.exec ('mv %s %s', dir..'temp', dir..filename)
      end
   end
end




local function makePrepare (recipe, s)
   local p = recipe.prepare
   local patchdir

   s:write ('\nprepare_rules() {\n')

   if type (p) == 'string' then
      s:write ('\n# rules:\n' .. p) -- short form of 'prepare.rules:' is just 'prepare:'
   elseif type (p) == 'table' then

      if p.patches then
         patchdir = conf.wok .. recipe.name .. '/patches/'
         lib.emptyDir (patchdir)

         s:write ('\n# patches:\n')
         for _, v in ipairs (p.patches) do
            if v.url then
               getPatchFromUrl (v, patchdir)
            elseif v.name then
               getFileFromRecipe (recipe, v.name, patchdir)
            end

            s:write (lib.printf('patch %s -i %s\n', (v.args or '-Np1'), patchdir..v.name))

         end
      end

      if p.rules then
         s:write ('\n# rules:\n' .. p.rules)
      end

   else
      s:write (':\n') --define empty function
   end

   s:write ('}\n')
end




--[[
variants:

args: foo

args:
  - foo
  - bar

args:
  - foo: bar
  - baz: qux

args:         # mixed:
  - foo: bar  # foo="bar"
  - baz=qux   # baz=qux
  - rol:      # rol=""
  - ose       # ose
--]]

local function Pairs (branch, template)
   local out = ''
   if type (branch) == 'string' then
      out = out .. lib.printf (template, branch)
   elseif type (branch) == 'table' then
      for _, i in pairs (branch) do
         if type (i) == 'string' then
            out = out .. lib.printf (template, i)
         elseif type (i) == 'table' then
            for j,k in pairs (i) do
               out = out .. lib.printf (template, j..'="'..k..'"')
            end
         end
      end
   end
   return out
end




local function makeMake (recipe, s)
   local m = recipe.make

   if not m then
      return -- no make rules
   end

   s:write ('\nmake_rules() {\n')

   s:write (Pairs (m.env, 'export %s\n'))

   -- use <defargs: ''> to DISABLE adding default $CONFIGURE_ARGS
   if not m.defargs then
      m.defargs = '$CONFIGURE_ARGS '
   else
      m.defargs = ''
   end

   if m.type == 'gnu' then
      s:write (
         Pairs (m.vars, '%s \\\n') ..
         './configure \\\n' ..
         Pairs (m.args,    '\t%s \\\n') ..
         Pairs (m.defargs, '\t%s&&\n') ..
         "if [ -e 'libtool' ]; then\n" ..
         "\tsed -i 's| -shared | -Wl,-Os,--as-needed\\0|g' libtool\n" ..
         "fi &&\n" ..
         Pairs (m.makevars, '%s ') .. 'make ' .. Pairs (m.jobs, '-j%s ') .. Pairs (m.makeargs, '%s ') .. '&&\n' ..
         Pairs (m.makevars, '%s ') .. 'make ' .. Pairs (m.jobs, '-j%s ') .. Pairs (m.makeargs, '%s ') ..
         Pairs (m.destdir, 'DESTDIR=$install ') .. 'install || return 1\n'
         )

   elseif m.type == 'perl' then
      s:write (
         'PERL_MM_USE_DEFAULT=1 \\\n' .. Pairs (m.vars, '%s \\\n') ..
         'perl Makefile.PL \\\n' ..
         '\tINSTALLDIRS=vendor \\\n' .. Pairs (m.args, '\t%s \\\n') ..
         '\t&&\n' ..
         Pairs (m.makevars, '%s ') .. 'make ' .. Pairs (m.jobs, '-j%s ') .. Pairs (m.makeargs, '%s ') .. '&&\n' ..
         Pairs (m.makevars, '%s ') .. 'make ' .. Pairs (m.jobs, '-j%s ') .. Pairs (m.makeargs, '%s ') ..
         'PERL_MM_USE_DEFAULT=1 DESTDIR=$install install &&\n' ..
         'chmod -R u+w $install\n'
         )

   elseif m.type == 'cmake' then
      s:write (
         Pairs ((m.build or 'build'), 'mkdir %s\n') ..
         Pairs ((m.build or 'build'), 'cd    %s\n') ..
         Pairs (m.vars, '%s \\\n') ..
         'cmake \\\n' ..
         Pairs (m.args, '\t%s \\\n') ..
         '\t.. &&\n' ..
         Pairs (m.makevars, '%s ') .. 'make ' .. Pairs (m.jobs, '-j%s ') .. Pairs (m.makeargs, '%s ') .. '&&\n' ..
         Pairs (m.makevars, '%s ') .. 'make ' .. Pairs (m.jobs, '-j%s ') .. Pairs (m.makeargs, '%s ') ..
         Pairs (m.destdir, 'DESTDIR=$install ') .. 'install || return 1\n'
         )

   elseif m.type == 'meson' then
      s:write (
         Pairs ((m.build or 'build'), 'mkdir %s\n') ..
         Pairs ((m.build or 'build'), 'cd    %s\n') ..
         Pairs (m.vars, '%s \\\n') ..
         'meson-wrapper \\\n' ..
         Pairs (m.args, '\t%s \\\n') ..
         '\t&&\n' ..
         Pairs (m.ninjavars, '%s ') .. 'ninja ' .. Pairs (m.jobs, '-j%s ') .. Pairs (m.ninjaargs, '%s ') .. '&&\n' ..
         Pairs (m.ninjavars, '%s ') .. 'ninja ' .. Pairs (m.jobs, '-j%s ') .. Pairs (m.ninjaargs, '%s ') ..
         Pairs (m.destdir, 'DESTDIR=$install ') .. 'install || return 1\n'
         )

   elseif m.type == 'python2' then
      s:write (
         'python2 -B setup.py install ' .. Pairs (m.args, '%s ') .. '--root=$install &&\n' ..
         "find $install -type f -name '*.pyc' -delete\n"
         )

   elseif m.type == 'python3' then
      s:write (
         'python3 -B setup.py install ' .. Pairs (m.args, '%s ') .. '--root=$install &&\n' ..
         "find $install -type f -name '*.pyc' -delete\n"
         )

   elseif m.type == 'python2+3' then
      s:write (
         -- use $install for python2
         'python2 -B setup.py install ' .. Pairs (m.args, '%s ') .. '--root=$install &&\n' ..
         "find $install -type f -name '*.pyc' -delete\n" ..
         -- use $install-3 for python3
         'python3 -B setup.py install ' .. Pairs (m.args, '%s ') .. '--root=$install-3 &&\n' ..
         "find $install-3 -type f -name '*.pyc' -delete\n"
         )

   elseif m.type == 'ruby' then
      s:write (
         [[
gem install \
  --no-document \
  --ignore-dependencies \
  --no-user-install \
  --build-root $install \
  $src/$TARBALL \
]] ..
         Pairs (m.args, '  %s \\\n') ..
         '  || return 1\n'..
         Pairs (m.insert, '%s') ..
         [[

# some useful operations while Ruby gems cooking
_gems="$(ruby -e'puts Gem.default_dir')"

# remove unwanted empty folders
rmdir --ignore-fail-on-non-empty \
  $install/$_gems/build_info/ \
  $install/$_gems/cache/ \
  $install/$_gems/doc/ \
  $install/$_gems/extensions/

# move files to docdir
docdir=$install/usr/share/doc/$PACKAGE-$VERSION
for i in $(ls -ap $install/$_gems/gems/${PACKAGE#*-}-$VERSION/ | sed '
  /\/$/d; /^\./d; /gemspec$/d; /Rakefile*/d; /Gemfile*/d; /Makefile/d;
  /\.c$/d; /\.h$/d; /\.o$/d; /\.rb$/d; /\.so$/d; /\.yml$/d;
  /Manifest/d; /\.inc$/d; /depend/d;
  '); do
  mkdir -p $docdir # docdir will not be created when nothing to move
  mv $install/$_gems/gems/${PACKAGE#*-}-$VERSION/$i $docdir
done
if [ -d $install/$_gems/gems/${PACKAGE#*-}-$VERSION/doc/ ]; then
  mkdir -p $docdir
  mv $install/$_gems/gems/${PACKAGE#*-}-$VERSION/doc/ $docdir
fi

if [ -d $docdir ]; then
  # move man pages
  unset man_to_copy
  for i in $(seq 1 8); do
    for j in $(find $docdir -type f -name "*.$i" | sed '/LGPL-2\.1/d'); do
      man_to_copy="$man_to_copy $j"
    done
  done
  if [ -n "$man_to_copy" ]; then
    cook_pick_manpages $man_to_copy
    rm $man_to_copy
  fi

  # Install UTF-8 locale
  tazpkg -gi --quiet --local --cookmode locale-en-base
  mkdir -p /usr/lib/locale
  localedef -i 'en_US' -c -f 'UTF-8' /usr/lib/locale/en_US.UTF-8
  # convert rdoc to markdown (thanks https://gist.github.com/teeparham/8a99e308884e1c32735a)
  for i in $(find $docdir -type f -name '*.rdoc'); do
    LC_ALL=en_US.UTF-8 \
    ruby -r rdoc -e 'puts RDoc::Markup::ToMarkdown.new.convert File.read(ARGV[0] || "'$i'")' \
    >$i.md && rm $i || rm $i.md
  done
fi

# move man pages (from the different place)
rubyman=$install/$_gems/gems/${PACKAGE#*-}-$VERSION/man
if [ -d $rubyman ]; then
  unset man_to_copy
  for i in $(seq 1 8); do
    for j in $(find $rubyman -type f -name "*.$i" | sed '/LGPL-2\.1/d'); do
      man_to_copy="$man_to_copy $j"
    done
  done
  if [ -n "$man_to_copy" ]; then
    cook_pick_manpages $man_to_copy
  fi
  rm -r $rubyman
fi
]])

   end

   s:write (Pairs (m.rules, '%s\n'))

   s:write ('}\n')
end




-- if the file defined in 'files:' then install it from $files (it is already there),
-- otherwise install it from current path ($src)
local function installFile (recipe, name, to, mode)
   local prefix = ''

   if recipe.files then
      for _,i in ipairs (recipe.files) do
         if i.name == name then
            prefix = '$files/'
         end
      end
   end

   return (lib.printf ('install -Dm%s %s %s\n', mode, prefix..name, to))
end


local function installBranch (recipe, branch, to, mode)
   local ret = ''
   if branch then
      if type (branch) == 'string' then
         ret = ret .. installFile (recipe, branch, to..branch, mode)
      elseif type (branch) == 'table' then
         for _,i in ipairs (branch) do
            if type (i) == 'string' then
               ret = ret .. installFile (recipe, i, to..i, mode)
            elseif type (i) == 'table' then
               if i.to:match ('/$') then
                  -- install to specified folder with the original name
                  ret = ret .. installFile (recipe, i.from, '$install'..i.to..i.from, (i.mode or '644'))
               else
                  -- install to specified folder/name
                  ret = ret .. installFile (recipe, i.from, '$install'..i.to,         (i.mode or '644'))
               end
            end
         end
      end
   end
   return ret
end




local function iconSize (fileName)
   local file, w, h, tmp, svg, ew, eh, ev, v

   -- four bytes - to size
   local function qb2s (qb)
      return (((qb:byte(1) * 256 + qb:byte(2)) * 256 + qb:byte(3)) * 256 + qb:byte(4))
   end

   file = io.open (fileName, 'rb')

   if fileName:match ('%.png$') then
      file:seek ('set', 16)    -- skip 16 bytes
      w = qb2s (file:read (4)) -- https://www.w3.org/TR/PNG/#11IHDR
      h = qb2s (file:read (4))
      file:close ()
   elseif fileName:match ('%.svg$') then
      -- yes, using regexps to parse an XML, but kitten will be alive :-)
      tmp  = file:read ('*a')
      file:close ()
      svg  = tmp:gsub ('.*<svg([^>]*)>.*$'  , '%1') :gsub ('[\a\r]', ' ')

      w,ew = svg:gsub ('.*width="(%d+)p*x*".*$' , '%1')
      h,eh = svg:gsub ('.*height="(%d+)p*x*".*$', '%1')
      if ew == 0 or eh == 0 then
         -- 'width="..."' and/or 'heigth="..."' missing, try to use 'viewBox="..."'
         v,ev = svg:gsub ('.*viewBox="([^"]+)".*$', '%1')
         if ev ~= 0 then
            w,ew = v:gsub ('[%d%.]+[^%d%.]+[%d%.]+[^%d%.]+([%d%.]+)[^%d%.]+[%d%.]+', '%1')
            h,eh = v:gsub ('[%d%.]+[^%d%.]+[%d%.]+[^%d%.]+[%d%.]+[^%d%.]+([%d%.]+)', '%1')
            if ew == 0 or eh == 0 then w,h = 0, 0 end
         else
            return 0, 0 -- error
         end
      end
   else
      return 0, 0 -- error
   end
   return w, h
end


--[[

| cmd: foo        | desktop: foo.desktop
|-----------------|-------------------------------------
| cmd: [foo, bar] | desktop: [foo.desktop, bar.desktop]
|-----------------|-------------------------------------
| cmd:            | desktop:
| - foo           | - foo.desktop
| - bar           | - bar.desktop

---

|file:
|- from: foo
|  to  : /usr/share/bar/ # copy 'foo' to folder '/usr/share/bar/'
  # default mode is 644
|- from: bar
|  to  : /usr/share/baz  # copy 'bar' as file '/usr/share/baz'
|  mode: 444

---

if nothing but 'rules:', short form allowed:
|post:
|  rules: <rules>

|post: <rules>

---

icon:
- name: foo.png  # file name from the 'files:' branch
  to  : bar.png  # optional new file name (allow name without '.png' or '.svg')
  cat : status   # optional; default is 'apps'
  size: 48       # optional; default is WxH read from file; also 'scalable' and 'symbolic' are supported
- from: icons/foo.svg # file name related to $src
  to  : home     # optional new file name (allow name without '.png' or '.svg')
  cat : places   # optional; default is 'apps'
  size: 16       # mandatory, because we can't guess the size at the rules creation time
--]]

local function makePost (recipe, s)
   local p = recipe.post
   local w,h, filesdir, dir, basename

   -- shell functions to copy man pages and docs
   s:write [[
scopy() {
   if [ "$(stat -c %h -- "$1")" -eq 1 ]; then
      cp -a  "$1" "$2"  # copy generic files
   else
      cp -al "$1" "$2"  # copy hardlinks
   fi
}
cook_pick_manpages() {
   local name section
   for i in $@; do
      name=$(echo $i | sed 's|\.[gbx]z2*$||')
      section=${name##*/}; section=${section##*.}
      mkdir -p $install/usr/share/man/man$section
      scopy $i $install/usr/share/man/man$section
   done
}
cook_pick_docs() {
   local docdir="$install/usr/share/doc/$PACKAGE-$VERSION"
   mkdir -p $docdir
   cp -r $@ $docdir
   chmod -R a+r $docdir
}
]]

   s:write ('\npost_rules() {\n')

   if type (p) == 'string' then
      s:write (Pairs (p, '%s\n')) -- short form, only rules
   elseif type (p) == 'table' then
      s:write (Pairs (p.rules, '%s\n'))

      s:write (installBranch (recipe, p.cmd,     '$install/usr/bin/',           '755'))
      s:write (installBranch (recipe, p.desktop, '$install/usr/share/desktop/', '644'))
      s:write (installBranch (recipe, p.file))

      if p.icon then
         filesdir = conf.wok .. recipe.name .. '/files/'
         lib.emptyDir (filesdir)

         for _,j in ipairs (p.icon) do
            if j.name then
               getFileFromRecipe (recipe, j.name, filesdir)
               if j.size then
                  if j.size == 'scalable' or j.size == 'symbolic' then
                     dir = j.size
                  else
                     dir = j.size .. 'x' .. j.size
                  end
               else
                  w,h = iconSize (filesdir..j.name)
                  dir = w .. 'x' .. h
               end
               s:write (lib.printf ('install -Dm644 %s $install/usr/share/icons/hicolor/%s/%s/%s\n',
                  filesdir..j.name, dir, (j.cat or 'apps'), (j.to or j.name))
                  )
            elseif j.from then
               if j.size then
                  if j.size == 'scalable' or j.size == 'symbolic' then
                     dir = j.size
                  else
                     dir = j.size .. 'x' .. j.size
                  end
               else
                  die ('Undefined size to copy icon')
               end
               basename = j.from:gsub ('^.*/', '')
               s:write (lib.printf ('install -Dm644 $src/%s $install/usr/share/icons/hicolor/%s/%s/%s\n',
                  j.from, dir, (j.cat or 'apps'), (j.to or basename))
                  )
            end
         end
      end

      s:write (Pairs (p.doc, 'cook_pick_docs %s\n'))
      s:write (Pairs (p.man, 'cook_pick_manpages %s\n'))

   else
      s:write ('\t:\n')
   end


   s:write ('}\n')
end




local function makeTest (recipe, s)
   local t = recipe.test

   s:write ('\ntest_rules() {\n')

   if type (t) == 'string' then
      s:write (t .. '\n') -- short form of 'test.rules:' is just 'test:'
   elseif type (t) == 'table' then
      if t.rules then
         s:write (t.rules .. '\n')
      else
         s:write (':\n') --define empty function
      end
   else
      s:write (':\n') --define empty function
   end

   s:write ('}\n')
end




local function make (recipe, script)
   local s -- script handler
   s = io.open (script, 'w')

   local tarball
   if recipe.src then tarball = recipe.src[1].file end

   s:write (
      '# global variables:\n' ..
      Pairs (conf.flags[conf.arch], 'export %s\n') ..

      '\n# package variables:\n' ..
      Pairs (recipe.name,    'PACKAGE="%s"\n') ..
      Pairs (recipe.version, 'VERSION="%s"\n') ..
      Pairs (tarball,        'TARBALL="%s"\n') ..

      '\n# useful variables:\n' ..
      'src="'     .. conf.wok .. recipe.name .. '/src/' .. recipe.name .. '-' .. recipe.version ..'"\n' ..
      'install="' .. conf.wok .. recipe.name .. '/install"\n' ..
      'files="'   .. conf.wok .. recipe.name .. '/files"\n'
      )

   makePrepare (recipe, s)
   makeMake    (recipe, s)
   makePost    (recipe, s)
   makeTest    (recipe, s)

   s:write [[

if [ -n "$continue" ]; then
   prepare_rules || return 1
fi
make_rules &&
post_rules &&
test_rules
]]

   s:close()
end




return {
   make = make
}
