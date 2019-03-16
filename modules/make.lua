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




local function outputList (branch, template, branchName)
   local out = ''
   if type (branch) == 'string' then
      out = out .. lib.printf (template, branch)
   elseif type (branch) == 'table' then
      for _, j in ipairs (branch) do
         out = out .. lib.printf (template, j)
      end
   else
      die ('Unsufficient type (%s) of "%s"', type(branch), branchName)
   end
   return out
end




local function outputPairs (branch, templateStr, template, branchName)
   local out = ''
   if type (branch) == 'string' then
      out = out .. lib.printf (templateStr, branch)
   elseif type (branch) == 'table' then
      for i, j in pairs (branch) do
         if type (j) == 'string' then
            out = out .. lib.printf (template, i, j)
         elseif type (j) == 'table' then
            for k, l in pairs (j) do
               out = out .. lib.printf (template, k, l)
            end
         else
            die ('Unsufficient type (%s) of "%s[%s][%s]"', type(j), branchName, i, j)
         end
      end
   else
      die ('Unsufficient type (%s) of "%s"', type(branch), branchName)
   end
   return out
end




local function makeMake (recipe, s)
   local m = recipe.make

   if not m then
      return -- no make rules
   end

   s:write ('\nmake_rules() {\n')

   if m.env then
      s:write (outputPairs (m.env, 'export %s\n', 'export %s="%s"\n', 'make.env'))
      s:write ('\n')
   end

   if m.type == 'gnu' then

      s:write ('# type: gnu\n')

      if m.vars then
         s:write (outputPairs (m.vars, '%s \\\n', '%s="%s" \\\n', 'make.vars'))
      end

      s:write ('./configure \\\n')

      if m.args then
         s:write (outputList (m.args, '\t%s \\\n', 'make.args'))
      end

      s:write ('\t$CONFIGURE_ARGS &&\n')


      -- fix libtool (if any)
      s:write ("if [ -e 'libtool' ]; then\n")
      s:write ("\tsed -i 's| -shared | -Wl,-Os,--as-needed\\0|g' libtool\n")
      s:write ("fi &&\n")


      -- make
      if m.makevars then
         s:write (outputPairs (m.makevars, '%s ', '%s="%s" ', 'make.makevars'))
      end

      s:write ('make ')

      if m.jobs then
         s:write (lib.printf ('-j%s ', m.jobs))
      end

      if m.makeargs then
         s:write (outputPairs (m.makeargs, '%s ', '%s="%s" ', 'make.makeargs'))
      end

      s:write ('&&\n')

      -- make install
      if m.makevars then
         s:write (outputPairs (m.makevars, '%s ', '%s="%s" ', 'make.makevars'))
      end

      s:write ('make ')

      if m.jobs then
         s:write (lib.printf ('-j%s ', m.jobs))
      end

      if m.makeargs then
         s:write (outputPairs (m.makeargs, '%s ', '%s="%s" ', 'make.makeargs'))
      end

      if m.destdir and m.destdir == 'keep' then
         s:write ('DESTDIR=$install ')
      end

      s:write ('install || return 1\n')

   end

   s:write ('\n}\n')
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

   s:write ('# global variables:\n')
   for i, j in pairs (conf.flags[conf.arch]) do
      if type (j) == 'string' then
         s:write (lib.printf('%s="%s"\n', i, j))
      elseif type (j) == 'table' then
         for k, l in pairs (j) do
            s:write (lib.printf('%s="%s"\n', k, l))
         end
      end
   end

   s:write ('\n# package variables:\n')
   s:write ('PACKAGE="' .. recipe.name .. '"\n')
   s:write ('VERSION="' .. recipe.version .. '"\n')

   -- FIXME
   s:write ('\n# useful variables:\n')
   s:write ('src="..."\n')
   s:write ('install="..."\n')

   makePrepare (recipe, s)
   makeMake    (recipe, s)
   makePost    (recipe, s)
   makeTest    (recipe, s)

   s:close()
end




return {
   makePrepare = makePrepare,
   makeMake    = makeMake,
   makePost    = makePost,
   makeTest    = makeTest,
   make        = make
}
