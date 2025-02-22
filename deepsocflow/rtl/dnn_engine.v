`timescale 1ns/1ps
`define VERILOG
`include "defines.svh"
`undef  VERILOG

module dnn_engine #(
    parameter   ROWS                    = `ROWS               ,
                COLS                    = `COLS               ,
                X_BITS                  = `X_BITS             , 
                K_BITS                  = `K_BITS             , 
                Y_BITS                  = `Y_BITS             ,
                M_DATA_WIDTH_HF_CONV    = COLS  * ROWS  * Y_BITS,
                M_DATA_WIDTH_HF_CONV_DW = ROWS  * Y_BITS,

                S_PIXELS_WIDTH_LF       = `S_PIXELS_WIDTH_LF  ,
                S_WEIGHTS_WIDTH_LF      = `S_WEIGHTS_WIDTH_LF ,
                M_OUTPUT_WIDTH_LF       = `M_OUTPUT_WIDTH_LF  ,

                OUT_ADDR_WIDTH          = 10,
                OUT_BITS                = 32
  )(
    input  wire aclk,
    input  wire aresetn,

    output wire s_axis_pixels_tready,
    input  wire s_axis_pixels_tvalid,
    input  wire s_axis_pixels_tlast ,
    input  wire [S_PIXELS_WIDTH_LF  -1:0]   s_axis_pixels_tdata,
    input  wire [S_PIXELS_WIDTH_LF/8-1:0]   s_axis_pixels_tkeep,

    output wire s_axis_weights_tready,
    input  wire s_axis_weights_tvalid,
    input  wire s_axis_weights_tlast ,
    input  wire [S_WEIGHTS_WIDTH_LF  -1:0]  s_axis_weights_tdata,
    input  wire [S_WEIGHTS_WIDTH_LF/8-1:0]  s_axis_weights_tkeep,

    input  wire m_axis_tready, 
    output wire m_axis_tvalid, m_axis_tlast,
    output wire [M_OUTPUT_WIDTH_LF   -1:0] m_axis_tdata,
    output wire [M_OUTPUT_WIDTH_LF/8 -1:0] m_axis_tkeep
  ); 

  localparam  TUSER_WIDTH = `TUSER_WIDTH;

  /* WIRES */

  wire pixels_m_valid, pixels_m_ready;
  wire weights_m_valid, weights_m_ready, weights_m_last;
  wire conv_s_valid, conv_s_ready;
  wire [X_BITS*ROWS -1:0] pixels_m_data;
  wire [K_BITS*COLS -1:0] weights_m_data;
  wire [TUSER_WIDTH -1:0] weights_m_user;


  // Unpack tkeep_bytes into tkeep_words
  wire [S_PIXELS_WIDTH_LF /X_BITS-1:0]  s_axis_pixels_tkeep_words;
  wire [S_WEIGHTS_WIDTH_LF/K_BITS-1:0]  s_axis_weights_tkeep_words;

  genvar ik, ix;
  generate
    for (ix=0; ix<S_PIXELS_WIDTH_LF/X_BITS; ix=ix+1) begin
      assign s_axis_pixels_tkeep_words[ix] = s_axis_pixels_tkeep[ix/(8/X_BITS)];
    end

    for (ik=0; ik<S_WEIGHTS_WIDTH_LF/K_BITS; ik=ik+1) begin
      assign s_axis_weights_tkeep_words[ik] = s_axis_weights_tkeep[ik/(8/K_BITS)];
    end
  endgenerate

  axis_pixels PIXELS (
    .aclk   (aclk   ),
    .aresetn(aresetn),
    .s_ready(s_axis_pixels_tready),
    .s_valid(s_axis_pixels_tvalid),
    .s_last (s_axis_pixels_tlast ),
    .s_data (s_axis_pixels_tdata ),
    .s_keep (s_axis_pixels_tkeep_words),
    .m_valid(pixels_m_valid      ),
    .m_ready(pixels_m_ready      ),
    .m_data (pixels_m_data       )
  );

  axis_weight_rotator WEIGHTS_ROTATOR (
    .aclk          (aclk                 ),
    .aresetn       (aresetn              ),
    .s_axis_tready (s_axis_weights_tready), 
    .s_axis_tvalid (s_axis_weights_tvalid), 
    .s_axis_tlast  (s_axis_weights_tlast ), 
    .s_axis_tdata  (s_axis_weights_tdata ),
    .s_axis_tkeep  (s_axis_weights_tkeep_words),
    .m_axis_tready (weights_m_ready      ),      
    .m_axis_tvalid (weights_m_valid      ),   
    .m_axis_tdata  (weights_m_data       ),
    .m_axis_tlast  (weights_m_last       ),
    .m_axis_tuser  (weights_m_user       ) 
  );

  axis_sync SYNC (
    .weights_m_valid (weights_m_valid), 
    .pixels_m_valid  (pixels_m_valid ), 
    .m_axis_tready   (conv_s_ready   ),
    .weights_m_user  (weights_m_user ),
    .m_axis_tvalid   (conv_s_valid   ), 
    .weights_m_ready (weights_m_ready), 
    .pixels_m_ready  (pixels_m_ready ) 
  );

  wire m_ready, m_valid, m_last;
  wire [M_DATA_WIDTH_HF_CONV_DW -1:0] m_data;

  proc_engine_out PROC_OUT (
    .aclk           (aclk    ),
    .aresetn        (aresetn ),
    .s_valid        (conv_s_valid               ),
    .s_ready        (conv_s_ready               ),
    .s_last         (weights_m_last             ),
    .s_user         (weights_m_user             ),
    .s_data_pixels  (pixels_m_data              ),
    .s_data_weights (weights_m_data             ),
    .m_ready        (m_ready                    ),
    .m_valid        (m_valid                    ),
    .m_data         (m_data                     ),
    .m_last_pkt     (),
    .m_last         (m_last                     )
  );

  localparam Y_BITS_PADDED = 2**$clog2(Y_BITS);
  localparam Y_PADDING     = Y_BITS_PADDED-Y_BITS;
  genvar iy;
  
  wire [Y_BITS_PADDED*ROWS-1:0] m_data_padded;
  generate
    for (iy=0; iy<ROWS; iy=iy+1) begin
      // Sign padding: can be done as $signed(), but verilator gives warning for width mismatch
      wire sign_bit = m_data[Y_BITS*(iy+1)-1];
      assign m_data_padded[Y_BITS_PADDED*(iy+1)-1:Y_BITS_PADDED*iy] = {{Y_PADDING{sign_bit}}, m_data[Y_BITS*(iy+1)-1:Y_BITS*iy]};
    end
  endgenerate
  

  alex_axis_adapter_any #(
    .S_DATA_WIDTH  (Y_BITS_PADDED*ROWS),
    .M_DATA_WIDTH  (M_OUTPUT_WIDTH_LF ),
    .S_KEEP_ENABLE (1),
    .M_KEEP_ENABLE (1),
    .S_KEEP_WIDTH  (Y_BITS_PADDED*ROWS/8),
    .M_KEEP_WIDTH  (M_OUTPUT_WIDTH_LF/8),
    .ID_ENABLE     (0),
    .DEST_ENABLE   (0),
    .USER_ENABLE   (0)
  ) DW (
    .clk           (aclk         ),
    .rst           (~aresetn     ),
    .s_axis_tready (m_ready      ),
    .s_axis_tvalid (m_valid      ),
    .s_axis_tdata  (m_data_padded),
    .s_axis_tlast  (m_last       ),
    .s_axis_tkeep  ({(Y_BITS_PADDED*ROWS/8){1'b1}}),
    .m_axis_tready (m_axis_tready),
    .m_axis_tvalid (m_axis_tvalid),
    .m_axis_tdata  (m_axis_tdata ),
    .m_axis_tlast  (m_axis_tlast ),
    .m_axis_tkeep  (m_axis_tkeep ),
    .s_axis_tid    (8'b0),
    .s_axis_tdest  (8'b0),
    .s_axis_tuser  (1'b0),
    .m_axis_tid    (),
    .m_axis_tdest  (),
    .m_axis_tuser  ()
  );
endmodule


module proc_engine_out #(
  parameter 
    M_DATA_WIDTH_HF_CONV = `COLS  * `ROWS  * `Y_BITS,
    M_DATA_WIDTH_HF_CONV_DW = `ROWS  * `Y_BITS
)(
    input wire aclk          ,
    input wire aresetn       ,
    input wire s_valid       ,
    output wire s_ready       ,
    input wire s_last        ,
    input wire [`TUSER_WIDTH  -1:0] s_user        ,
    input wire [`X_BITS*`ROWS -1:0] s_data_pixels ,
    input wire [`K_BITS*`COLS -1:0] s_data_weights,

    input wire m_ready,
    output wire m_valid,
    output wire [M_DATA_WIDTH_HF_CONV_DW-1:0] m_data,
    output wire m_last_pkt,
    output wire m_last 
  );

  wire conv_m_axis_tready, conv_m_axis_tvalid, conv_m_axis_tlast ;
  wire [`TUSER_WIDTH         -1:0] conv_m_axis_tuser;
  wire [M_DATA_WIDTH_HF_CONV -1:0] conv_m_axis_tdata; // cgmu

  proc_engine PROC_ENGINE (
    .clk            (aclk    ),
    .resetn         (aresetn ),
    .s_valid        (s_valid                    ),
    .s_ready        (s_ready                    ),
    .s_last         (s_last                     ),
    .s_user         (s_user                     ),
    .s_data_pixels  (s_data_pixels              ),
    .s_data_weights (s_data_weights             ),
    .m_valid        (conv_m_axis_tvalid         ),
    .m_ready        (conv_m_axis_tready         ),
    .m_data         (conv_m_axis_tdata          ),
    .m_last         (conv_m_axis_tlast          ),
    .m_user         (conv_m_axis_tuser          )
  );
  axis_out_shift OUT (
    .aclk    (aclk   ),
    .aresetn (aresetn),
    .s_ready (conv_m_axis_tready    ),
    .s_valid (conv_m_axis_tvalid    ),
    .s_data  (conv_m_axis_tdata     ),
    .s_user  (conv_m_axis_tuser     ),
    .s_last  (conv_m_axis_tlast     ),
    .m_ready (m_ready               ),
    .m_valid (m_valid               ),
    .m_data  (m_data                ),
    .m_last_pkt (m_last_pkt         ),
    .m_last  (m_last                ),
    .m_user  ()
  );

endmodule
