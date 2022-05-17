/***********************************************************************

    	Copyright 1997 Willows Software, Inc. 

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Library General Public License as
published by the Free Software Foundation; either version 2 of the
License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Library General Public License for more details.

You should have received a copy of the GNU Library General Public
License along with this library; see the file COPYING.LIB.  If
not, write to the Free Software Foundation, Inc., 675 Mass Ave,
Cambridge, MA 02139, USA.


For more information about the Willows Twin Libraries.

	http://www.willows.com	

To send email to the maintainer of the Willows Twin Libraries.

	mailto:twin@willows.com 

***********************************************************************/
/***************************************************************************************
**
**
**                              Dialog Box Related Functions
**
**
***************************************************************************************/

#ifndef DIALOGS_H
#define DIALOGS_H

/***********************************
**
**  System Includes
**
***********************************/

#include <windows.h>


/***********************************
**
**  Shared Function Prototypes
**
***********************************/

BOOL CALLBACK __export AboutDlgProc( HWND hWnd, UINT wMsg, WPARAM wParam, LPARAM lParam );

#endif


