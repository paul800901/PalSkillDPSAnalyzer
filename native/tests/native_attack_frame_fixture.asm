; Actual Windows x64 unwind metadata. The callee deliberately overwrites both
; source registers, so reading the wrong frame cannot accidentally pass.
PUBLIC FixtureFilter, FixtureFilterReturn, FixtureDamage, FixtureDamageEnd
PUBLIC FixtureOtherCaller
PUBLIC FixtureBlueprint, FixtureBlueprintReturn
.code
; Same preserved FFrame register and actor local slots as execProcessDamage.
FixtureBlueprint PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 40h
    .allocstack 40h
    .endprolog
    mov rbx, rcx
    mov [rsp + 38h], rdx
    mov [rsp + 30h], r8
    mov rcx, r9
    call FixtureDamage
FixtureBlueprintReturn LABEL BYTE
    add rsp, 40h
    pop rbx
    ret
FixtureBlueprint ENDP

FixtureFilter PROC FRAME
    push rsi
    .pushreg rsi
    push r12
    .pushreg r12
    sub rsp, 28h
    .allocstack 28h
    .endprolog
    mov rsi, rcx
    mov r12, rdx
    mov rcx, r8
    call FixtureDamage
FixtureFilterReturn LABEL BYTE
    add rsp, 28h
    pop r12
    pop rsi
    ret
FixtureFilter ENDP

FixtureDamage PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    push r12
    .pushreg r12
    sub rsp, 20h
    .allocstack 20h
    .endprolog
    mov rsi, 777h
    mov r12, 888h
    mov rbx, 999h
    call rcx
    add rsp, 20h
    pop r12
    pop rsi
    pop rbx
    ret
FixtureDamage ENDP
FixtureDamageEnd LABEL BYTE

FixtureOtherCaller PROC FRAME
    sub rsp, 28h
    .allocstack 28h
    .endprolog
    call FixtureDamage
    add rsp, 28h
    ret
FixtureOtherCaller ENDP
END
