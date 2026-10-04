if exists('g:loaded_vim_tools_java_tools')
  finish
endif
let g:loaded_vim_tools_java_tools = 1

let s:vim_home = fnamemodify(expand('<sfile>:p'), ':h:h:h')
let s:helper = s:vim_home . '/bin/java-project.pl'
let s:perl = exepath('perl')
if empty(s:perl)
  let s:perl = 'perl'
endif

function! s:Helper(args) abort
  let l:parts = [s:perl, s:helper] + a:args
  let l:cmd = join(map(l:parts, 'shellescape(v:val)'), ' ')
  let l:out = systemlist(l:cmd)
  if v:shell_error
    echohl ErrorMsg
    echom join(l:out, "\n")
    echohl None
    return []
  endif
  return l:out
endfunction

function! s:RunJavaTest(kind, debug) abort
  if &filetype !=# 'java'
    echoerr 'Java test commands require a Java buffer'
    return
  endif
  let l:args = ['plan', '--file', expand('%:p'), '--line', string(line('.')), '--kind', a:kind]
  if a:debug
    call add(l:args, '--debug')
  endif
  let l:out = s:Helper(l:args)
  if empty(l:out)
    return
  endif
  try
    let l:plan = json_decode(join(l:out, "\n"))
    let l:opts = {'cwd': l:plan.cwd, 'env': l:plan.env, 'term_name': 'Java tests: ' . l:plan.selector}
    call term_start(l:plan.argv, l:opts)
    if a:debug
      echom 'Test JVM will wait for a debugger on localhost:5005. Use :CocCommand java.debug.vimspector.start to attach.'
    endif
  catch
    echoerr 'Could not start Java test command: ' . v:exception
  endtry
endfunction

function! JavaTestNearest() abort
  call s:RunJavaTest('nearest', 0)
endfunction

function! JavaTestFile() abort
  call s:RunJavaTest('file', 0)
endfunction

function! JavaDebugTestNearest() abort
  if !get(g:, 'vim_tools_java_debugger_enabled', 0)
    echoerr 'Test debugging needs Vim +python3 and Python 3.10+; rerun the installer after adding them'
    return
  endif
  call s:RunJavaTest('nearest', 1)
endfunction

function! JavaFindTest() abort
  let l:out = s:Helper(['find-test', '--file', expand('%:p')])
  if empty(l:out)
    return
  endif
  execute 'edit ' . fnameescape(l:out[0])
endfunction

function! JavaCoverage() abort
  if &filetype !=# 'java'
    echoerr 'Java coverage requires a Java buffer'
    return
  endif
  let l:out = s:Helper(['coverage', expand('%:p')])
  if empty(l:out)
    return
  endif
  try
    let l:lines = json_decode(join(l:out, "\n"))
    call sign_unplace('JavaCoverage', {'buffer': bufnr('%')})
    call sign_define('VimToolsJavaCovered', {'text': '✓', 'texthl': 'DiffAdd'})
    let l:id = 1
    for l:lnum in l:lines
      call sign_place(l:id, 'JavaCoverage', 'VimToolsJavaCovered', bufnr('%'), {'lnum': l:lnum, 'priority': 8})
      let l:id += 1
    endfor
    echom printf('JaCoCo: %d covered source lines', len(l:lines))
  catch
    echoerr 'Could not read JaCoCo coverage: ' . v:exception
  endtry
endfunction

function! s:HasErrors() abort
  let l:info = get(b:, 'coc_diagnostic_info', {})
  if get(l:info, 'error', 0) > 0
    return 1
  endif
  if !exists('*CocAction')
    return 0
  endif
  try
    let l:diagnostics = CocAction('getDiagnostics')
    if type(l:diagnostics) == v:t_dict
      let l:diagnostics = get(l:diagnostics, bufnr('%'), [])
    endif
    return !empty(filter(copy(l:diagnostics), 'get(v:val, "severity", 0) == 1'))
  catch
    return 0
  endtry
endfunction

function! JavaWriteAndTest() abort
  if s:HasErrors()
    echoerr 'Write cancelled: Java diagnostics contain errors'
    return
  endif
  write
  if &filetype ==# 'java'
    JavaTestFile()
  endif
endfunction

function! JavaWriteAndQuit() abort
  if s:HasErrors()
    echoerr 'Quit cancelled: diagnostics contain errors'
    return
  endif
  write
  quit
endfunction

function! s:JavaClassColumn() abort
  if expand('<cword>') =~# '^\u'
    return col('.')
  endif

  let l:reference = matchstrpos(getline('.'), '\<[a-z][[:alnum:]_$]*\%(\.[[:alnum:]_$]\+\)*\.[A-Z][[:alnum:]_$]*\>')
  let l:cursor = col('.') - 1
  if l:reference[1] < 0 || l:cursor < l:reference[1] || l:cursor >= l:reference[2]
    return 0
  endif

  let l:class = matchstrpos(l:reference[0], '[A-Z][[:alnum:]_$]*$')
  return l:reference[1] + l:class[1] + 1
endfunction

function! s:JavaClassName() abort
  let l:reference = matchstrpos(getline('.'), '\<[a-z][[:alnum:]_$]*\%(\.[[:alnum:]_$]\+\)*\.[A-Z][[:alnum:]_$]*\>')
  let l:cursor = col('.') - 1
  if l:reference[1] >= 0 && l:cursor >= l:reference[1] && l:cursor < l:reference[2]
    return l:reference[0]
  endif

  let l:class = expand('<cword>')
  if l:class !~# '^\u'
    return ''
  endif

  for l:line in getline(1, '$')
    let l:import = matchlist(l:line, '^\s*import\s\+\([A-Za-z_][A-Za-z0-9_$.]*\)\s*;')
    if !empty(l:import) && fnamemodify(substitute(l:import[1], '\.', '/', 'g'), ':t:r') ==# l:class
      return l:import[1]
    endif
  endfor

  for l:line in getline(1, min([line('$'), 100]))
    let l:package = matchlist(l:line, '^\s*package\s\+\([A-Za-z_][A-Za-z0-9_.]*\)\s*;')
    if !empty(l:package)
      return l:package[1] . '.' . l:class
    endif
  endfor
  return l:class
endfunction

function! s:JavaProjectSource(class_name) abort
  let l:relative = substitute(a:class_name, '\.', '/', 'g') . '.java'
  let l:directory = fnamemodify(expand('%:p:h'), ':p')
  while !empty(l:directory)
    if filereadable(l:directory . '/pom.xml')
      for l:source_root in ['src/main/java', 'src/test/java', 'src/it/java']
        let l:candidate = l:directory . '/' . l:source_root . '/' . l:relative
        if filereadable(l:candidate)
          return l:candidate
        endif
        let l:matches = globpath(l:directory, '**/' . l:source_root . '/' . l:relative, 0, 1)
        for l:match in l:matches
          if filereadable(l:match)
            return l:match
          endif
        endfor
      endfor
    endif
    if isdirectory(l:directory . '/.git')
      break
    endif
    let l:parent = fnamemodify(l:directory, ':h')
    if l:parent ==# l:directory
      break
    endif
    let l:directory = l:parent
  endwhile
  return ''
endfunction

function! s:JavaMavenSource(class_name) abort
  if !executable('unzip')
    return ''
  endif

  let l:parts = split(a:class_name, '\.')
  if len(l:parts) < 3
    return ''
  endif
  let l:relative = join(l:parts, '/') . '.java'
  let l:repository = expand('~/.m2/repository')
  let l:first_group_size = max([2, len(l:parts) - 3])
  for l:group_size in reverse(range(l:first_group_size, len(l:parts) - 1))
    let l:group = join(l:parts[0 : l:group_size - 1], '/')
    let l:root = l:repository . '/' . l:group
    if !isdirectory(l:root)
      continue
    endif
    let l:jars = systemlist('find ' . shellescape(l:root) . ' -type f -name ' . shellescape('*-sources.jar') . ' -print 2>/dev/null')
    if v:shell_error
      continue
    endif
    for l:jar in l:jars
      let l:entries = systemlist('unzip -Z1 ' . shellescape(l:jar) . ' ' . shellescape(l:relative) . ' 2>/dev/null')
      if v:shell_error == 0 && index(l:entries, l:relative) >= 0
        return 'zipfile://' . l:jar . '::' . l:relative
      endif
    endfor
  endfor
  return ''
endfunction

function! VimToolsJavaGotoOrTab(direction) abort
  if &filetype !=# 'java'
    execute 'normal! ' . (a:direction > 0 ? 'gt' : 'gT')
    return
  endif

  let l:class_column = s:JavaClassColumn()
  if l:class_column == 0
    execute 'normal! ' . (a:direction > 0 ? 'gt' : 'gT')
    return
  endif

  let l:class_name = s:JavaClassName()
  call cursor(line('.'), l:class_column)
  let l:source = empty(l:class_name) ? '' : s:JavaProjectSource(l:class_name)
  if empty(l:source) && !empty(l:class_name)
    let l:source = s:JavaMavenSource(l:class_name)
  endif
  if !empty(l:source)
    execute 'edit ' . fnameescape(l:source)
    return
  endif

  if exists('*CocAction') && get(g:, 'coc_service_initialized', 0)
        \ && CocAction('hasProvider', 'definition')
    call CocActionAsync('jumpDefinition')
    return
  endif
  echohl WarningMsg
  echom 'Java class definition not found: ' . l:class_name
  echohl None
endfunction

function! VimToolsGotoFile(kind) abort
  if &filetype ==# 'perl'
    let l:args = ['resolve-module', '--line', getline('.'), '--column', string(col('.')), '--cwd', getcwd()]
    let l:out = s:Helper(l:args)
    if empty(l:out)
      return
    endif
    let l:command = a:kind =~# '^split' ? 'split' : (a:kind =~# '^tab' ? 'tabedit' : 'edit')
    execute l:command . ' ' . fnameescape(l:out[0])
    return
  endif
  if a:kind ==# 'edit' && &filetype ==# 'java' && exists('*CocActionAsync')
    call feedkeys("\<Plug>(coc-definition)", 'm')
    return
  endif
  if a:kind ==# 'split'
    execute "normal! \<C-w>f"
  elseif a:kind ==# 'tab'
    execute "normal! \<C-w>gf"
  elseif a:kind ==# 'split-line'
    execute "normal! \<C-w>F"
  elseif a:kind ==# 'tab-line'
    execute "normal! \<C-w>gF"
  else
    normal! gf
  endif
endfunction

nnoremap <silent> gf :call VimToolsGotoFile('edit')<CR>
nnoremap <silent> <C-w>f :call VimToolsGotoFile('split')<CR>
nnoremap <silent> <C-w>F :call VimToolsGotoFile('split-line')<CR>
nnoremap <silent> <C-w>gf :call VimToolsGotoFile('tab')<CR>
nnoremap <silent> <C-w>gF :call VimToolsGotoFile('tab-line')<CR>
nnoremap <silent> gt :bnext<CR>
nnoremap <silent> gT :bprevious<CR>
command! JavaTestNearest call JavaTestNearest()
command! JavaTestFile call JavaTestFile()
command! JavaDebugTestNearest call JavaDebugTestNearest()
command! JavaFindTest call JavaFindTest()
command! JavaCoverage call JavaCoverage()

if exists('*sign_getplaced')
  function! s:CoverageDoubleClick() abort
    let l:pos = getmousepos()
    if empty(l:pos) || l:pos.line < 1
      return
    endif
    let l:placed = sign_getplaced(bufnr('%'), {'lnum': l:pos.line})
    if !empty(l:placed) && !empty(get(l:placed[0], 'signs', []))
      if index(map(copy(l:placed[0].signs), 'get(v:val, "name", "")'), 'VimToolsJavaCovered') >= 0
        call JavaFindTest()
      endif
    endif
  endfunction
  nnoremap <silent> <2-LeftMouse> :call <SID>CoverageDoubleClick()<CR>
endif
