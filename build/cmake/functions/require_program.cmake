function(require_program name)
  find_program(${name} ${name})
  if(NOT ${name})
    MESSAGE(FATAL_ERROR "Could not find ${name}")
  endif()
endfunction(require_program)
