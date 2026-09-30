#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <WinSock2.h>
#include <MSWSock.h>
#include <Windows.h>
#include <cstddef>
#include <cstdio>

int main()
{
    std::printf("WSADATA=%zu\n", sizeof(WSADATA));
    std::printf("SOCKADDR_IN=%zu\n", sizeof(SOCKADDR_IN));
    std::printf("SOCKADDR_STORAGE=%zu\n", sizeof(SOCKADDR_STORAGE));
    std::printf("OVERLAPPED=%zu\n", sizeof(OVERLAPPED));
    std::printf("RIO_BUF=%zu\n", sizeof(RIO_BUF));
    std::printf("RIORESULT=%zu\n", sizeof(RIORESULT));
    std::printf("RIO_NOTIFICATION_COMPLETION=%zu\n", sizeof(RIO_NOTIFICATION_COMPLETION));
    std::printf("RIO_EXTENSION_FUNCTION_TABLE=%zu\n", sizeof(RIO_EXTENSION_FUNCTION_TABLE));
    std::printf("SO_UPDATE_ACCEPT_CONTEXT=%d\n", SO_UPDATE_ACCEPT_CONTEXT);
    std::printf("SOCKADDR_IN.sin_port=%zu\n", offsetof(SOCKADDR_IN, sin_port));
    std::printf("OVERLAPPED.hEvent=%zu\n", offsetof(OVERLAPPED, hEvent));
    std::printf("RIORESULT.RequestContext=%zu\n", offsetof(RIORESULT, RequestContext));
    std::printf("RIO_NOTIFICATION_COMPLETION.Iocp=%zu\n", offsetof(RIO_NOTIFICATION_COMPLETION, Iocp));
}
