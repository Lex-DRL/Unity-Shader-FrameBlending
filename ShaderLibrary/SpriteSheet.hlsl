#ifndef DRL_SHADER_SPRITE_SHEET_LIB_INCLUDED
#define DRL_SHADER_SPRITE_SHEET_LIB_INCLUDED

#ifdef __RESHARPER__
#endif

// Might define an override-macro for half:
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
// it ^ also includes a macro for float/half epsilon values


// ========================================================
// Utility functions

// ------------------------------------
// For given frame-ID(s), calculates the actual sprite-sheet UVs.

half2 GetSpriteSheetUVs_half(half2 uv, half frameID, half2 sheetCells, bool topToBottom)
{
	// Prerequisites:
	//   sheetCells: int-as-half, 1+
	//   frameID: int-as-half, [1, sheetCells.x * sheetCells.y - 1]
	
	// E.g.:
	// sheetCells = (4, 3)
	// frameID = 0/1/.../11
	half2 cellSize = (half2)1.0h / sheetCells;
	
	half2 uvOffsets;
	// First, detect U/V cell-IDs (int-values, 0+):
	uvOffsets.x = frameID % sheetCells.x; // 0/1/2/3
	uvOffsets.y = (frameID - uvOffsets.x) * cellSize.x; // 0/1/2
	// Here ^ '* cellSize.x' is actually an optimized version of '/ sheetCells.x'.
	// Unless we have ridiculously high cell-counts (like, HUNDREDS of frames in each dimension),
	// the result is the same as division, and float errors are negligible.
	// However, if we DO have such high cell counts (could be, if 1 cell = 1 pixel, possible for various VATs),
	// We should perform the true division here... and we also should probably work
	// in full-float precision till the very end of the function,
	// unless cell counts are guaranteed to ALWAYS be powers of 2.
	// So, for a regular sprite sheet this tiny optimization is OK, but don't use the function for VATs.
	
	// Now, turn cell-IDs into actual UV-offsets:
	uvOffsets *= cellSize; // (0/0.25/0.5/0.75, 0/0.33.../0.66...)
	if(topToBottom) {
		// The provided sprite-sheet progresses from top to bottom (though still left-to-right).
		// We need to invert offset in V:
		uvOffsets.y = 1.0h - uvOffsets.y - cellSize.y;
	}
	return uv * cellSize + uvOffsets;
}
// Two-UVs vectorized overload, to calculate both current/next UVs at once:
half4 GetSpriteSheetUVs_half(half2 uv, half2 frameIDs, half2 sheetCells, bool topToBottom)
{
	half2 cellSize = (half2)1.0h / sheetCells;
	half4 uvOffsets;
	// xy - current frame
	// zw - next frame
	uvOffsets.xz = frameIDs % sheetCells.xx;
	uvOffsets.yw = (frameIDs - uvOffsets.xz) * cellSize.xx;
	uvOffsets *= cellSize.xyxy;
	if(topToBottom) {
		uvOffsets.yw = 1.0h - uvOffsets.yw - cellSize.yy;
	}
	half2 scaledUVs = uv.xy * cellSize;
	return scaledUVs.xyxy + uvOffsets;
}
// Float overloads:
float2 GetSpriteSheetUVs_float(float2 uv, float frameID, float2 sheetCells, bool topToBottom)
{
	float2 cellSize = (float2)1.0 / sheetCells;
	float2 uvOffsets;
	uvOffsets.x = frameID % sheetCells.x;
	uvOffsets.y = (frameID - uvOffsets.x) * cellSize.x;
	uvOffsets *= cellSize;
	if(topToBottom) {
		uvOffsets.y = 1.0 - uvOffsets.y - cellSize.y;
	}
	return uv * cellSize + uvOffsets;
}
float4 GetSpriteSheetUVs_float(float2 uv, float2 frameIDs, float2 sheetCells, bool topToBottom)
{
	float2 cellSize = (float2)1.0 / sheetCells;
	float4 uvOffsets;
	uvOffsets.xz = frameIDs % sheetCells.xx;
	uvOffsets.yw = (frameIDs - uvOffsets.xz) * cellSize.xx;
	uvOffsets *= cellSize.xyxy;
	if(topToBottom) {
		uvOffsets.yw = 1.0 - uvOffsets.yw - cellSize.yy;
	}
	float2 scaledUVs = uv.xy * cellSize;
	return scaledUVs.xyxy + uvOffsets;
}

// ========================================================
// High-level functions (ShaderGraph)

// 'sheetCells' parameter might've been defined as a "true" int,
// and all the ID calculations then would be done as true ints, too.
// But ints are still emulated or just buggy on some old (yet still used) mobile platforms.
// So it's safer to do an old-school half-as-int now (2024).
// In a couple of years, when android 8/9 devices are FULLY deprecated, it might be beneficial to
// do the exact opposite: _enforce_ ints or even uints to help a compiler.

void SpriteSheet_FrameBlending_Looping_half(
	half2 uv, half2 sheetCells, half progress, bool topToBottom,
	out half4 sheetUVs, out half blend
)
{
	// Prerequisites:
	//   sheetCells: int-as-half, 1+
	//   progress: [0, 1]
	// E.g.:
	// sheetCells = (4, 3)
	sheetCells = max(sheetCells, half2(1.0h, 1.0h)); // fool-proof, prevent division by zero
	half totalSize = sheetCells.x * sheetCells.y; // 12
	half idProgress = totalSize * progress; // continuous, [0, 12] - yes, 12 itself is included
	
	half2 frameIDs;
	// x - current frame
	// y - next frame
	frameIDs.x = floor(idProgress);
	blend = idProgress - frameIDs.x;
	frameIDs.y = frameIDs.x + 1.0h;

	// Now, loop the frame-ID-progress while simultaneously turning it into [0, 11] range.
	// So, 12 => 0.
	// To fight potential float-rounding errors (and never have '-0.0...01' prior to modulo),
	// let's shift the value up by 0.5:
	frameIDs += 0.5h;
	frameIDs = frameIDs % (half2)totalSize;
	frameIDs -= 0.5h; // ... and shift it back to an int value after looping.

	// As a nice side effect of this ^ trickery, now we can pass scaled time as progress,
	// though it's not advised due to cumulative loss of float precision.
	// If you wish to link progress to time, "the right way" to do it
	// is pre-ensuring (outside the func) that progress is in [0, 1].
	// The safest way to do so is like this (preserves as much precision as possible):
	// frequency = 1.0 / speed; // we determine the SMALL range to loop the "unscaled time" in.
	// progress = (time % frequency) * speed;
	// // loop time in the range ^, and after multiplying it by speed,
	// // the scaled time now loops in [0, 1]. 1.0 exactly is still possible due to float errors.

	// We finally have frame-IDs which are:
	// - int-as-half
	// - in the right range (0-11)
	// - loop properly
	// Let's get the actual UVs now:
	sheetUVs = GetSpriteSheetUVs_half(uv, frameIDs, sheetCells, topToBottom);
}
// Float overload:
void SpriteSheet_FrameBlending_Looping_float(
	float2 uv, float2 sheetCells, float progress, bool topToBottom,
	out float4 sheetUVs, out float blend
)
{
	sheetCells = max(sheetCells, float2(1.0, 1.0));
	float totalSize = sheetCells.x * sheetCells.y;
	float idProgress = totalSize * progress;
	float2 frameIDs;
	frameIDs.x = floor(idProgress);
	blend = idProgress - frameIDs.x;
	frameIDs.y = frameIDs.x + 1.0;
	frameIDs += 0.5;
	frameIDs = frameIDs % (float2)totalSize;
	frameIDs -= 0.5;
	sheetUVs = GetSpriteSheetUVs_float(uv, frameIDs, sheetCells, topToBottom);
}

#endif
