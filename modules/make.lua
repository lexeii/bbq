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




local function getPatchFromRecipe (recipe, filename, dir)
   local index, hand

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
      lib.exec ('cp %s %s', recipe.files[index].link, dir..filename)

   elseif recipe.files[index].content then
      hand = io.open (dir..'temp', 'w')
      hand:write (recipe.files[index].content)
      hand:close () -- or file will be partially saved

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

   if not p then
      return -- no prepare rules
   end

   s:write ('\nprepare_rules() {\n')

   if p.patches then
      patchdir = conf.wok .. recipe.name .. '/patches/'
      lib.emptyDir (patchdir)

      s:write ('\n# patches:\n')
      for _, v in ipairs (p.patches) do
         if v.url then
            getPatchFromUrl (v, patchdir)
         elseif v.name then
            getPatchFromRecipe (recipe, v.name, patchdir)
         end

         s:write (lib.printf('patch %s -i %s\n', (v.args or '-Np1'), patchdir..v.name))

      end
   end

   if p.rules then
      s:write ('\n# rules:\n' .. p.rules)
   end

   s:write ('\n}\n')
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
         'python2 -B setup.py install --root=$install &&\n' ..
         "find $install -type f -name '*.pyc' -delete\n"
         )

   elseif m.type == 'python3' then
      s:write (
         'python3 -B setup.py install --root=$install &&\n' ..
         "find $install -type f -name '*.pyc' -delete\n"
         )

   elseif m.type == 'python2+3' then
      s:write (
         'python2 -B setup.py install --root=$install &&\n' ..   -- use $install for python2
         "find $install -type f -name '*.pyc' -delete\n" ..
         'python3 -B setup.py install --root=$install-3 &&\n' .. -- use $install-3 for python3
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

   s:write ('}\n')
end




local function makePost (recipe, s)
   local p = recipe.post

   if not p then
      return -- no post rules
   end

   s:write ('\npost_rules() {\n')

   if p.rules then
      s:write ('# rules\n')
   end

   s:write ('\n}\n')
end




local function makeTest (recipe, s)
   local t = recipe.test

   if not t then
      return -- no test rules
   end

   s:write ('\ntest_rules() {\n')

   if t.rules then
      s:write ('# rules\n')
   end

   s:write ('\n}\n')
end




local function make (recipe, script)
   local s -- script handler
   s = io.open (script, 'w')

   s:write (
      '# global variables:\n' ..
      Pairs (conf.flags[conf.arch], 'export %s\n') ..

      '\n# package variables:\n' ..
      'PACKAGE="' .. recipe.name .. '"\n' ..
      'VERSION="' .. recipe.version .. '"\n' ..
      'TARBALL="' .. recipe.src[1].file .. '"\n' ..

      '\n# useful variables:\n' ..
      'src="'     .. conf.wok .. recipe.name .. '/src/' .. recipe.name .. '-' .. recipe.version ..'"\n' ..
      'install="' .. conf.wok .. recipe.name .. '/install"\n'
      )

   makePrepare (recipe, s)
   makeMake    (recipe, s)
   makePost    (recipe, s)
   makeTest    (recipe, s)

   s:close()
end




return {
   make        = make
}
