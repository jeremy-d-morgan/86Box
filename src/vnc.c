/*
 * 86Box    A hypervisor and IBM PC system emulator that specializes in
 *          running old operating systems and software designed for IBM
 *          PC systems and compatibles from 1981 through fairly recent
 *          system designs based on the PCI bus.
 *
 *          This file is part of the 86Box distribution.
 *
 *          Implement the VNC remote renderer with LibVNCServer.
 *
 * Authors: Fred N. van Kempen, <decwiz@yahoo.com>
 *          Based on raw code by RichardG, <richardg867@gmail.com>
 *
 *          Copyright 2017-2019 Fred N. van Kempen.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <rfb/rfb.h>
#define HAVE_STDARG_H
#include <86box/86box.h>
#include <86box/device.h>
#include <86box/video.h>
#include <86box/keyboard.h>
#include <86box/mouse.h>
#include <86box/plat.h>
#include <86box/ui.h>
#include <86box/vnc.h>

#define VNC_MIN_X 320
#define VNC_MAX_X 2048
#define VNC_MIN_Y 200
#define VNC_MAX_Y 2048

static rfbScreenInfoPtr rfb = NULL;
static int              clients;
static int              ptr_x;
static int              ptr_y;
static int              ptr_but;

#ifdef ENABLE_VNC_LOG
int vnc_do_log = ENABLE_VNC_LOG;

static void
vnc_log(const char *fmt, ...)
{
    va_list ap;

    if (vnc_do_log) {
        va_start(ap, fmt);
        pclog_ex(fmt, ap);
        va_end(ap);
    }
}
#else
#    define vnc_log(fmt, ...)
#endif

static void
vnc_kbdevent(rfbBool down, rfbKeySym k, rfbClientPtr cl)
{
    (void) cl;

    /* Handle it through the lookup tables. */
    vnc_kbinput(down ? 1 : 0, (int) k);
}

static void
vnc_ptrevent(int but, int x, int y, rfbClientPtr cl)
{
    int dx;
    int dy;
    int b;

    b = 0x00;
    if (but & 0x01)
        b |= 0x01;
    if (but & 0x02)
        b |= 0x04;
    if (but & 0x04)
        b |= 0x02;
    mouse_set_buttons_ex(b);
    ptr_but = but;

    dx = (x - ptr_x) / 0.96; /* TODO: Figure out the correct scale factor for X and Y. */
    dy = (y - ptr_y) / 0.96;

    /* VNC uses absolute positions within the window, no deltas. */
    mouse_scale(dx, dy);

    ptr_x = x;
    ptr_y = y;

    mouse_x_abs = (double)ptr_x / (double)VNC_MAX_X;
    mouse_y_abs = (double)ptr_y / (double)VNC_MAX_Y;

    if (mouse_x_abs > 1.0) mouse_x_abs = 1.0;
    if (mouse_y_abs > 1.0) mouse_y_abs = 1.0;
    if (mouse_x_abs < 0.0) mouse_x_abs = 0.0;
    if (mouse_y_abs < 0.0) mouse_y_abs = 0.0;

    /* Do not call rfbDefaultPtrAddEvent — it triggers server-side software
       cursor rendering which computes garbage rect sizes from an uninitialized
       cursor sprite, causing "rect too big" disconnects.  The VM renders its
       own cursor into the framebuffer so no server-side cursor is needed. */
}

static void
vnc_clientgone(UNUSED(rfbClientPtr cl))
{
    vnc_log("VNC: client disconnected: %s\n", cl->host);

    if (clients > 0)
        clients--;
    if (clients == 0) {
        /* No more clients, pause the emulator. */
        vnc_log("VNC: no clients, pausing..\n");

        /* Disable the mouse. */
#if 0
        plat_mouse_capture(0);
#endif

        plat_pause(1);
    }
}

static enum rfbNewClientAction
vnc_newclient(rfbClientPtr cl)
{
    /* Hook the ClientGone function so we know when they're gone. */
    cl->clientGoneHook = vnc_clientgone;

    /* Disable server-side cursor encoding.  The VM renders its own cursor
       into the framebuffer.  libvncserver's RichCursor path can produce
       garbage-dimensioned cursor rects (0xFFFF x 0xFFF8) that cause
       "rect too big" disconnects in VNC clients. */
    cl->enableCursorShapeUpdates = FALSE;
    cl->enableCursorPosUpdates   = FALSE;
    cl->useRichCursorEncoding    = FALSE;
    cl->cursorWasChanged         = FALSE;
    cl->cursorWasMoved           = FALSE;

    vnc_log("VNC: new client: %s\n", cl->host);
    if (++clients == 1) {
        /* Reset the mouse. */
        ptr_x   = VNC_MAX_X / 2;
        ptr_y   = VNC_MAX_Y / 2;
        mouse_clear_coords();
        mouse_clear_buttons();

        /* We now have clients, un-pause the emulator if needed. */
        vnc_log("VNC: unpausing..\n");

        /* Enable the mouse. */
#if 0
        plat_mouse_capture(1);
#endif

        plat_pause(0);
    }

    /* For now, we always accept clients. */
    return RFB_CLIENT_ACCEPT;
}

static void
vnc_display(rfbClientPtr cl)
{
    /* libvncserver re-enables cursor shape updates when it processes the
       client's SetEncodings message (after vnc_newclient returns).  Clear
       the flags here, which runs just before rfbSendFramebufferUpdate, so
       rfbSendCursorShape is never called.  The VM renders its own cursor. */
    cl->enableCursorShapeUpdates = FALSE;
    cl->enableCursorPosUpdates   = FALSE;
    cl->useRichCursorEncoding    = FALSE;
    cl->cursorWasChanged         = FALSE;
    cl->cursorWasMoved           = FALSE;
}

static void
vnc_blit(int x, int y, int w, int h, int monitor_index)
{
    if (monitor_index || (x < 0) || (y < 0) || (w < VNC_MIN_X) || (h < VNC_MIN_Y) || (w > VNC_MAX_X) || (h > VNC_MAX_Y) || (buffer32 == NULL)) {
        video_blit_complete_monitor(monitor_index);
        return;
    }

    /* Scale the native blit (w × h) to fill the declared VNC canvas
       (rfb->width × rfb->height).  This mirrors what the Qt renderer stack
       does when it stretches the blit to fill its widget — most visibly, the
       force_43 path computes a taller canvas height (e.g. 720×540 for a
       720×400 text mode) and the content must be vertically stretched to
       match.  Nearest-neighbor is sufficient for integer-ish scale factors. */
    int dst_w = (rfb != NULL && rfb->width  > 0) ? rfb->width  : w;
    int dst_h = (rfb != NULL && rfb->height > 0) ? rfb->height : h;

    for (int dst_row = 0; dst_row < dst_h; ++dst_row) {
        int src_row = dst_row * h / dst_h;
        uint8_t *dst_ptr = ((uint8_t *) rfb->frameBuffer) + (dst_row * VNC_MAX_X * sizeof(uint32_t));

        if (dst_w == w) {
            video_copy(dst_ptr, &(buffer32->line[y + src_row][x]), w * sizeof(uint32_t));
        } else {
            /* Horizontal nearest-neighbor stretch. */
            uint32_t *dst32 = (uint32_t *) dst_ptr;
            uint32_t *src32 = &(buffer32->line[y + src_row][x]);
            for (int dst_col = 0; dst_col < dst_w; ++dst_col)
                dst32[dst_col] = src32[dst_col * w / dst_w];
        }
    }

    if (screenshots)
        video_screenshot((uint32_t *) rfb->frameBuffer, 0, 0, VNC_MAX_X);

    video_blit_complete_monitor(monitor_index);

    rfbMarkRectAsModified(rfb, 0, 0, dst_w, dst_h);
}

/* Initialize VNC for operation. */
int
vnc_init(UNUSED(void *arg))
{
    static char    title[128];
    rfbPixelFormat rpf = {
        /*
         * Screen format:
         *  32bpp; 32 depth;
         *  little endian;
         *  true color;
         *  max 255 R/G/B;
         *  red shift 16; green shift 8; blue shift 0;
         *  padding
         */
        32, 32, 0, 1, 255, 255, 255, 16, 8, 0, 0, 0
    };

    plat_pause(1);
    cgapal_rebuild_monitor(0);

    if (rfb == NULL) {
        wchar_t *win_title = ui_window_title(NULL);
        wcstombs(title, win_title ? win_title : L"86Box", sizeof(title));

        /* Declare the screen at full VNC_MAX_X × VNC_MAX_Y.  Dynamic resize is
           suppressed (see vnc_resize), so we keep one fixed size for the whole
           session.  Using the max dimensions avoids any mismatch between the
           declared screen size and the paddedWidthInBytes stride that
           rfbGetScreen computes internally — mixing the two caused "rect too
           big" errors when the VNC client received a rect whose coordinates
           exceeded the overridden rfb->width/height. */
        rfb              = rfbGetScreen(0, NULL, VNC_MAX_X, VNC_MAX_Y, 8, 3, 4);
        rfb->desktopName = title;
        rfb->frameBuffer = (char *) calloc(VNC_MAX_X * VNC_MAX_Y, 4);

        rfb->serverFormat  = rpf;
        rfb->alwaysShared  = TRUE;
        rfb->displayHook   = vnc_display;
        rfb->ptrAddEvent   = vnc_ptrevent;
        rfb->kbdAddEvent   = vnc_kbdevent;
        rfb->newClientHook = vnc_newclient;

        rfbInitServer(rfb);

        /* Replace the default cursor with a 1×1 transparent one.  The VM
           renders its own cursor into the framebuffer; we don't want
           libvncserver to composite a server-side cursor sprite on top.
           A NULL cursor causes rfbSendCursorShape to read garbage and
           produce "rect too big" (65535×65528) errors in clients.  A
           valid 1×1 cursor is sent once and then suppressed by
           vnc_display clearing cursorWasChanged before every update. */
        rfbCursorPtr empty_cursor = rfbMakeXCursor(1, 1, " ", " ");
        rfbSetCursor(rfb, empty_cursor);

        rfbRunEventLoop(rfb, -1, TRUE);
    }

    /* Set up our BLIT handlers. */
    video_setblit(vnc_blit);

    clients = 0;

    vnc_log("VNC: init complete.\n");

    return 1;
}

void
vnc_close(void)
{
    video_setblit(NULL);

    if (rfb != NULL) {
        free(rfb->frameBuffer);

        rfbScreenCleanup(rfb);

        rfb = NULL;
    }
}

void
vnc_resize(int x, int y)
{
    rfbClientIteratorPtr iterator;
    rfbClientPtr         cl;

    if (rfb == NULL)
        return;

    if ((x < VNC_MIN_X) || (x > VNC_MAX_X) || (y < VNC_MIN_Y) || (y > VNC_MAX_Y))
        return;

    if (x == rfb->width && y == rfb->height)
        return;

    vnc_log("VNC: resize %dx%d\n", x, y);

    rfb->width  = x;
    rfb->height = y;

    iterator = rfbGetClientIterator(rfb);
    while ((cl = rfbClientIteratorNext(iterator)) != NULL) {
        LOCK(cl->updateMutex);
        cl->newFBSizePending = 1;
        UNLOCK(cl->updateMutex);
    }
    rfbReleaseClientIterator(iterator);
}

/* Tell them to pause if we have no clients. */
int
vnc_pause(void)
{
    return ((clients > 0) ? 0 : 1);
}

void
vnc_take_screenshot(UNUSED(wchar_t *fn))
{
    vnc_log("VNC: take_screenshot\n");
}
