 /*
    signals used in cdc_bridge : src_clk, src_rstn, pulse_in, dst_clk, dst_rstn, pulse_out are not mentioned in our module ports,
    so we need to connect them to the appropriate signals in our module ports.
    */

    module pulse_sync (
  input  logic src_clk,
  input  logic src_rstn,
  input  logic pulse_in,
  input  logic dst_clk,
  input  logic dst_rstn,
  output logic pulse_out
);

/* 
 we need to synchronize the toggle signal to the destination clock domain, 
 so we use a 2-stage synchronizer to avoid metastability issues.
 Metastability : condition where a signal is in an undefined state due to timing violations,
 which can cause some unpredictable behavior in digital circuits.
*/

  logic toggle_src;
  always_ff @(posedge src_clk or negedge src_rstn) begin
    if (!src_rstn) toggle_src <= 1'b0;
    else if (pulse_in) toggle_src <= ~toggle_src;
  end

  logic sync_ff1, sync_ff2, sync_ff3;
  always_ff @(posedge dst_clk or negedge dst_rstn) begin
    if (!dst_rstn) begin
      sync_ff1 <= 1'b0;
      sync_ff2 <= 1'b0;
      sync_ff3 <= 1'b0;
    end else begin
      sync_ff1 <= toggle_src;
      sync_ff2 <= sync_ff1;
      sync_ff3 <= sync_ff2;
    end
  end

  assign pulse_out = sync_ff2 ^ sync_ff3;

endmodule