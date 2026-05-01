#section definitions;
include "stddef";
include "stdio";
include "stdgfx";

def BALL_BASE_SPEED 2;

def LEVEL_WIDTH 30;
def LEVEL_HEIGHT 26;

def PIXEL_SIZE 8;

def RESOLUTION_X @COMPTIME_EVAL(LEVEL_WIDTH * PIXEL_SIZE);
def RESOLUTION_Y @COMPTIME_EVAL(LEVEL_HEIGHT * PIXEL_SIZE);

struct Ball {
    x: u16;
    y: u16;
};

struct Paddle {
    x: u16;
    y: u16;
    width: u16;
    height: u16;
};

#section data(0:0x00FF);
defaultStackEnd: @ZEROS(0xF01)
defaultStackBegin:

; page:startOffset
#section data(0:0x1000);

ball: type(Ball) @COMPTIME_EVAL(LEVEL_WIDTH / 2), @COMPTIME_EVAL(LEVEL_HEIGHT / 2);
paddle0: type(Paddle) @ZEROS(Paddle);
paddle1: type(Paddle) @ZEROS(Paddle);

paddle0Buffer: type(stdioConBuffer) @ZEROES(stdioConBuffer);
paddle1Buffer: type(stdioConBuffer) @ZEROES(stdioConBuffer);

#section text;
_start: 
    ; initialize stack
    mov r0, defaultStackBegin;
    mov r1, defaultStackEnd;
    sub r1, r0;
    stackset r0, r1;
    
    b initGfx;
    b initInput;

    ; yield to frame sync (so that we don't start mainLoop at a strange spot)
    yield;
    b mainLoop;

    hlt;

initInput:
    push jr;
    
    mov ra, stdio_ConfigPageID;
    
    mov rb, stdio_ControllerConfig;
    mov r0, 2;
    
    mov [ra, rb + @offsetof(stdioControllerConfig, numcontrollers)], r0;
    
    ; true/false found in stddef
    mov r0, TRUE;
    mov [ra, rb + @offsetof(stdioControllerConfig, enableController)], r0;
    ; constants can be chained if they're comptime known. Note that here we add 1
    ; entry, but because we're moving 16 bytes it'll get automatically resized to 2 bytes
    ; if we were moving in byte mode 1 would be taken literally as 1 byte.
    mov [ra, rb + @offsetof(stdioControllerConfig, enableController) + 1], r0;
    
    ; provide input buffers
    mov r0, paddle0Buffer;
    mov [ra, rb + @offsetof(stdioControllerConfig, conBuffer)], r0;
    mov r0, paddle1Buffer;
    mov [ra, rb + @offsetof(stdioControllerConfig, conBuffer) + 1], r0;
    xor r0, r0;
    mov [ra, rb + @offsetof(stdioControllerConfig, conBufferPageID)], r0;
    
    syscall stdio_SyncControllerConfig;
    
    pop jr;
    b jr;

initGfx:
    push jr;
    
    ; load gfx page id
    mov ra, stdgfx_ConfigPageId;
    
    ; load resolution config address
    mov rb, stdgfx_ResolutionConfig;
    
    ; Set resolution in graphics buffer
    mov r0, RESOLUTION_X;
    mov [ra, rb], r0;
    
    mov r0, RESOLUTION_Y;
    mov [ra, rb + 2], r0;
    
    ; initialize pixel_format to 32bit rgb+null
    mov rb, stdgfx_PixelConfig;
    mov r0, stdgfx_PixelRGBN32;
    mov [ra, rb], r0;
    
    ; initalize clear color
    mov rb, stdgfx_ClearColor;
    mov r0, 0x0010; clear color will be 0x101010XX;
    mov (byte) [ra, rb + @offsetof(stdgfxColorRGBN32, r)], r0;
    mov (byte) [ra, rb + @offsetof(stdgfxColorRGBN32, g)], r0;
    mov (byte) [ra, rb + @offsetof(stdgfxColorRGBN32, b)], r0;
    
    ; initialize fps
    mov rb, stdgfx_FPSFrame;
    mov r0, 30;
    mov [ra, rb], r0;
    
    syscall stdgfx_SyncGPUConfig;
    
    pop jr;
    b jr;
    
mainLoop:
    push jr;
    
    ; TODO: game init
    
gamePlay:
    ; TODO: game loop
    
    mov r0, endCondition;
    mov ra, gamePlay;
    bf ra, r0;
gameOver:
    pop jr;
    b jr;