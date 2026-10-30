// SPDX-License-Identifier: GPL-3.0-or-later
// Infinify canvas background renderer: IFBGShaderDecl, one uniform, varying or attribute declaration found in a user's GLSL ES 1.00 shader.
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d: the shader contract of
// src/render/background.rs (`references_uniform`) and src/render/shaders.rs
// (BG_UNIFORMS / BG_TEX_UNIFORMS), as the comments below cite.
// Split from native/desktop/background.m at 37b27b1.
#import <Foundation/Foundation.h>
@interface IFBGShaderDecl : NSObject
@property (nonatomic, copy) NSString *qualifier;  // uniform | varying | attribute
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSUInteger nameToken;       // index of the name in the token list
@property (nonatomic) BOOL isArray;
@end
