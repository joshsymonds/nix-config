package com.joshsymonds.hexrain;

/**
 * Texture geometry for the pre-passes: a port of DMS's
 * quickshell/Common/HexrainGrid.js (layouts are documented in
 * chrome_hexrain_cells.frag and chrome_hexrain_light.frag).
 */
final class HexrainGrid {
    /** Cells of margin around the canvas so neighbours of edge cells are in range. */
    static final int MARGIN = 2;
    /** Cell-pass texels per cell. */
    static final int CELL_TEXELS = 11;
    /** Light-pass blocks, each covering the whole canvas. */
    static final int LIGHT_BLOCKS = 3;
    /** Canvas pixels per light-pass texel. */
    static final int LIGHT_TEXEL_PX = 32;

    final int cols;
    final int rows;
    final int lightCols;
    final int lightRows;

    HexrainGrid(float cellSize, float resX, float resY) {
        float i = Math.max(1f, cellSize);
        float pitchX = 2f * i;
        float pitchY = 1.7320508f * i;
        cols = (int) Math.ceil(Math.max(resX, 0f) / pitchX) + 2 * MARGIN + 1;
        rows = (int) Math.ceil(Math.max(resY, 0f) / pitchY) + 2 * MARGIN + 1;
        lightCols = (int) Math.ceil(Math.max(resX, 0f) / LIGHT_TEXEL_PX) + 1;
        lightRows = (int) Math.ceil(Math.max(resY, 0f) / LIGHT_TEXEL_PX) + 1;
    }
}
