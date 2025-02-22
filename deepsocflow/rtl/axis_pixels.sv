`timescale 1ns/1ps
`include "defines.svh"

module axis_pixels #(
  parameter   ROWS               = `ROWS               ,
              KH_MAX             = `KH_MAX             ,
              CI_MAX             = `CI_MAX             ,
              XW_MAX             = `XW_MAX             ,
              XH_MAX             = `XH_MAX             ,
              WORD_WIDTH         = `X_BITS             ,
              RAM_EDGES_DEPTH    = `RAM_EDGES_DEPTH    , 
              S_PIXELS_WIDTH_LF  = `S_PIXELS_WIDTH_LF  ,

  localparam  EDGE_WORDS         =  KH_MAX/2              ,
              IM_SHIFT_REGS      =  ROWS + KH_MAX-1       ,
              BITS_KH            = $clog2(KH_MAX         ),
              BITS_KH2           = $clog2((KH_MAX+1)/2   ),
              BITS_CI            = $clog2(CI_MAX)         ,
              BITS_XW            = $clog2(XW_MAX)         ,
              BITS_IM_BLOCKS     = $clog2(XH_MAX/ROWS) 
  )(
    input logic aclk, aresetn,

    output logic s_ready,
    input  logic s_valid,
    input  logic s_last ,
    input  logic [S_PIXELS_WIDTH_LF/WORD_WIDTH-1:0][WORD_WIDTH-1:0] s_data,
    input  logic [S_PIXELS_WIDTH_LF/WORD_WIDTH-1:0] s_keep,

    input  logic m_ready,
    output logic m_valid,
    output logic [ROWS -1:0][WORD_WIDTH-1:0] m_data
  );

  logic dw_s_valid, dw_s_ready, dw_m_ready, dw_m_valid, dw_m_valid_r, dw_m_last, dw_m_last_r;
  logic [ROWS+EDGE_WORDS-1:0][WORD_WIDTH-1:0] dw_m_data, dw_m_data_r;

  alex_axis_adapter_any #(
    .S_DATA_WIDTH  (S_PIXELS_WIDTH_LF),
    .M_DATA_WIDTH  (WORD_WIDTH*(ROWS+EDGE_WORDS)),
    .S_KEEP_ENABLE (1),
    .M_KEEP_ENABLE (1),
    .S_KEEP_WIDTH  (S_PIXELS_WIDTH_LF/WORD_WIDTH),
    .M_KEEP_WIDTH  ((ROWS+EDGE_WORDS)),
    .ID_ENABLE     (0),
    .DEST_ENABLE   (0),
    .USER_ENABLE   (0)
    ) DW (
    .clk           (aclk       ),
    .rst           (~aresetn   ),
    .s_axis_tdata  (s_data     ),
    .s_axis_tkeep  (s_keep     ),
    .s_axis_tvalid (dw_s_valid ),
    .s_axis_tlast  (s_last     ),
    .s_axis_tready (dw_s_ready ),
    .s_axis_tid    ('0),
    .s_axis_tdest  ('0),
    .s_axis_tuser  ('0),
    .m_axis_tdata  (dw_m_data  ),
    .m_axis_tready (dw_m_ready ),
    .m_axis_tvalid (dw_m_valid ),
    .m_axis_tlast  (dw_m_last  ),
    .m_axis_tid    (),
    .m_axis_tdest  (),
    .m_axis_tkeep  (),
    .m_axis_tuser  ()
  );

  // State machine
  enum {SET, PASS , BLOCK} state;

  logic en_config, en_shift, en_copy, en_kh, en_copy_r, last_kh, last_kh_r, last_clk_kh, last_clk_kh_r, last_clk_ci, last_clk_w, last_l, last_l_r, m_last_reg, m_last, first_l, first_l_r;
  logic [BITS_KH2-1:0] ref_kh2, ref_kh2_in;
  logic [BITS_CI -1:0] ref_ci_in;
  logic [BITS_XW -1:0] ref_w_in ;
  logic [BITS_IM_BLOCKS-1:0] ref_l_in ;
  localparam BITS_REF = BITS_IM_BLOCKS + BITS_XW + BITS_CI + BITS_KH2;
  assign {ref_l_in, ref_w_in, ref_ci_in, ref_kh2_in} = BITS_REF'(s_data);

  wire dw_m_last_beat = dw_m_valid && dw_m_ready && dw_m_last;
  wire s_last_beat    = s_valid    && s_ready    && s_last;
  wire dw_m_beat      = dw_m_valid && dw_m_ready;
  wire m_last_beat    = m_ready    && m_valid    && m_last;
  wire m_beat         = m_ready    && m_valid;

  always_ff @(posedge aclk)
    if (!aresetn)                      state <= SET ;
    else case (state)
      SET   : if (s_valid && s_ready)  state <= PASS;
      PASS  : if (s_last_beat)
                if (m_last_beat)       state <= SET;
                else                   state <= BLOCK;
      BLOCK : if (m_last_beat)         state <= SET;
    endcase

  always_comb begin

    en_config    = 0;
    en_shift     = m_ready;
    en_kh        = m_ready && (last_kh ? (dw_m_valid | m_last_reg | dw_m_last_r) : 1);
    en_copy      = dw_m_valid && last_clk_kh && m_ready;
    
    unique case (state)
      SET  :  begin
                en_config    = 1;
                en_kh        = 0;
                en_shift     = 0;
                en_copy      = 0;

                s_ready      = 1;
                dw_s_valid   = 0;
                dw_m_ready   = 0;
              end
      PASS  : begin
                s_ready      = dw_s_ready;
                dw_s_valid   = s_valid;
                dw_m_ready   = en_copy;
              end
      BLOCK : begin
                s_ready      = 0;
                dw_s_valid   = 0;
                dw_m_ready   = en_copy;
            end
    endcase
  end

  // Counters: KH, CI, W, Blocks
  counter #(.W(BITS_KH)       ) C_KH (.clk(aclk), .reset(en_config), .en(en_kh      ), .max_in(BITS_KH'(ref_kh2_in*2)), .last_clk(last_clk_kh ), .last(last_kh),.first(),       .count());
  counter #(.W(BITS_CI)       ) C_CI (.clk(aclk), .reset(en_config), .en(last_clk_kh), .max_in(ref_ci_in             ), .last_clk(last_clk_ci ), .last(),       .first(),       .count());
  counter #(.W(BITS_XW)       ) C_W  (.clk(aclk), .reset(en_config), .en(last_clk_ci), .max_in(ref_w_in              ), .last_clk(last_clk_w  ), .last(),       .first(),       .count());
  counter #(.W(BITS_IM_BLOCKS)) C_L  (.clk(aclk), .reset(en_config), .en(last_clk_w ), .max_in(ref_l_in              ), .last_clk(),             .last(last_l), .first(first_l),.count());

  // RAM
  logic [$clog2(RAM_EDGES_DEPTH) -1:0] ram_addr, ram_addr_r, ram_addr_in;
  logic [EDGE_WORDS-1:0][WORD_WIDTH-1:0] ram_dout, ram_dout_hold, ram_dout_r, edge_top_r, edge_bot_r;

  always_ff @(posedge aclk)
    if (en_config || last_clk_w) ram_addr <= 0;
    else if (en_copy)            ram_addr <= ram_addr + 1;

  // ------------------ PIPELINE STAGE: (_R), to match RAM Read Latency = 1;

  wire ram_ren = en_copy   && !first_l;
  wire ram_wen = en_copy_r && !last_l_r;
  assign ram_addr_in = ram_wen ? ram_addr_r : ram_addr;

  ram_edges RAM (
    .clka  (aclk),    
    .ena   (ram_ren || ram_wen),     
    .wea   (ram_wen),     
    .addra (ram_addr_in),  
    .dina  (edge_bot_r),
    .douta (ram_dout)
  );

  // When ram_wen, read value is lost. This is used to hold that
  logic ram_ren_reg;
  always_ff @(posedge aclk) begin
    ram_ren_reg <= ram_ren;
    if (ram_ren_reg) ram_dout_hold <= ram_dout;
  end
  assign ram_dout_r = ram_ren_reg ? ram_dout : ram_dout_hold;


  always_ff @(posedge aclk)
    if (!aresetn)
      {first_l_r,last_l_r,last_clk_kh_r,en_copy_r,ram_addr_r,dw_m_data_r,dw_m_last_r} <= '0;
    else if (en_shift) begin // m_ready
      first_l_r     <= first_l;
      last_l_r      <= last_l;
      last_clk_kh_r <= last_clk_kh;
      last_kh_r     <= last_kh;
      en_copy_r     <= en_copy;
      ram_addr_r    <= ram_addr;
      dw_m_data_r   <= dw_m_data;
      dw_m_last_r   <= dw_m_last;
      dw_m_valid_r  <= dw_m_valid;
    end 
  assign edge_top_r = first_l_r ? '0 : ram_dout_r;
  assign edge_bot_r = dw_m_data_r[ROWS-1: ROWS-EDGE_WORDS];

  // Shift Regs
  logic [IM_SHIFT_REGS-1:0][WORD_WIDTH-1:0] shift_reg;

  always_ff @(posedge aclk)
    if      (en_copy_r && en_shift) shift_reg <= {dw_m_data_r, edge_top_r};
    else if (en_shift ) shift_reg <= shift_reg >> WORD_WIDTH;

  // Out mux
  always_ff @(posedge aclk )
    if (en_config) ref_kh2 <= ref_kh2_in;

  always_comb
    for (int r=0; r<ROWS; r=r+1)
      m_data[r] = shift_reg[r + EDGE_WORDS-32'(ref_kh2)];

  // m_valid, m_last

  always_ff @(posedge aclk)
    if (!aresetn || m_last_beat)       {m_valid, m_last_reg} <= '0;
    else begin 
      if (en_copy_r && en_shift) m_last_reg <= dw_m_last_r;
      if (last_kh_r && en_shift) m_valid    <= dw_m_valid_r;
    end
  
  assign m_last = m_last_reg && last_clk_kh_r;


endmodule