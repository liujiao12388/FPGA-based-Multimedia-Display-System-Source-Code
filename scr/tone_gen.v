//==========================================================================
// 模块：tone_gen —— 自研音频源（DDS 正弦旋律，柔和悦耳）
//--------------------------------------------------------------------------
// 一段 C 大调五声音阶旋律：正弦波 + 逐音符淡入淡出包络。
// 48kHz、24 位有符号立体声（左右相同），循环播放。
//
// · 正弦波音色柔和（非方波）
// · 淡入淡出消除咔哒、不刺耳
// · 16 音符 × 0.25s = 4 秒循环
// 时钟 25MHz，48kHz 用小数累加器精确产生。
//==========================================================================
module tone_gen #(
    parameter CLK_HZ = 25_000_000,
    parameter FS_HZ  = 48_000
)(
    input  wire        clk,
    input  wire        rst,
    output reg         audio_valid,
    output reg  [23:0] audio_left,
    output reg  [23:0] audio_right
);
    localparam [13:0] NOTE_LEN = 14'd12000;   // 每音符样本（0.25s）
    localparam [13:0] FADE     = 14'd1920;    // 淡入/淡出样本数
    localparam [3:0]  N_NOTE   = 4'd16;

    // 48kHz 节拍
    reg  [24:0] acc;
    wire        sample_now = (acc + FS_HZ >= CLK_HZ);

    reg  [13:0] note_cnt;
    reg  [3:0]  note_idx;
    reg  [31:0] phase;
    wire [31:0] phase_step = PS[note_idx];
    wire [7:0]  idx = phase[31:24];

    // 音符相位步进表
    reg [31:0] PS [0:15];
    initial begin
        PS[0]=32'd23410256; PS[1]=32'd29494793; PS[2]=32'd35075566; PS[3]=32'd46819617;
        PS[4]=32'd35075566; PS[5]=32'd29494793; PS[6]=32'd35075566; PS[7]=32'd58988691;
        PS[8]=32'd26276252; PS[9]=32'd35075566; PS[10]=32'd39370534; PS[11]=32'd35075566;
        PS[12]=32'd29494793; PS[13]=32'd26276252; PS[14]=32'd29494793; PS[15]=32'd23410256;
    end

    // 正弦查找表（256 点，24 位有符号）
    reg [23:0] sine_lut [0:255];
    initial begin
        sine_lut[0]=24'h000000; sine_lut[1]=24'h03242B; sine_lut[2]=24'h0647D9; sine_lut[3]=24'h096A90;
        sine_lut[4]=24'h0C8BD3; sine_lut[5]=24'h0FAB27; sine_lut[6]=24'h12C810; sine_lut[7]=24'h15E214;
        sine_lut[8]=24'h18F8B8; sine_lut[9]=24'h1C0B82; sine_lut[10]=24'h1F19F9; sine_lut[11]=24'h2223A5;
        sine_lut[12]=24'h25280C; sine_lut[13]=24'h2826B9; sine_lut[14]=24'h2B1F35; sine_lut[15]=24'h2E110A;
        sine_lut[16]=24'h30FBC5; sine_lut[17]=24'h33DEF2; sine_lut[18]=24'h36BA20; sine_lut[19]=24'h398CDD;
        sine_lut[20]=24'h3C56BA; sine_lut[21]=24'h3F1749; sine_lut[22]=24'h41CE1E; sine_lut[23]=24'h447ACD;
        sine_lut[24]=24'h471CEC; sine_lut[25]=24'h49B415; sine_lut[26]=24'h4C3FDF; sine_lut[27]=24'h4EBFE8;
        sine_lut[28]=24'h5133CC; sine_lut[29]=24'h539B2A; sine_lut[30]=24'h55F5A4; sine_lut[31]=24'h5842DD;
        sine_lut[32]=24'h5A8279; sine_lut[33]=24'h5CB420; sine_lut[34]=24'h5ED77C; sine_lut[35]=24'h60EC37;
        sine_lut[36]=24'h62F201; sine_lut[37]=24'h64E888; sine_lut[38]=24'h66CF80; sine_lut[39]=24'h68A69E;
        sine_lut[40]=24'h6A6D98; sine_lut[41]=24'h6C2429; sine_lut[42]=24'h6DCA0C; sine_lut[43]=24'h6F5F02;
        sine_lut[44]=24'h70E2CB; sine_lut[45]=24'h72552C; sine_lut[46]=24'h73B5EB; sine_lut[47]=24'h7504D2;
        sine_lut[48]=24'h7641AE; sine_lut[49]=24'h776C4E; sine_lut[50]=24'h788483; sine_lut[51]=24'h798A23;
        sine_lut[52]=24'h7A7D04; sine_lut[53]=24'h7B5D03; sine_lut[54]=24'h7C29FB; sine_lut[55]=24'h7CE3CE;
        sine_lut[56]=24'h7D8A5E; sine_lut[57]=24'h7E1D93; sine_lut[58]=24'h7E9D55; sine_lut[59]=24'h7F0991;
        sine_lut[60]=24'h7F6236; sine_lut[61]=24'h7FA736; sine_lut[62]=24'h7FD887; sine_lut[63]=24'h7FF621;
        sine_lut[64]=24'h7FFFFF; sine_lut[65]=24'h7FF621; sine_lut[66]=24'h7FD887; sine_lut[67]=24'h7FA736;
        sine_lut[68]=24'h7F6236; sine_lut[69]=24'h7F0991; sine_lut[70]=24'h7E9D55; sine_lut[71]=24'h7E1D93;
        sine_lut[72]=24'h7D8A5E; sine_lut[73]=24'h7CE3CE; sine_lut[74]=24'h7C29FB; sine_lut[75]=24'h7B5D03;
        sine_lut[76]=24'h7A7D04; sine_lut[77]=24'h798A23; sine_lut[78]=24'h788483; sine_lut[79]=24'h776C4E;
        sine_lut[80]=24'h7641AE; sine_lut[81]=24'h7504D2; sine_lut[82]=24'h73B5EB; sine_lut[83]=24'h72552C;
        sine_lut[84]=24'h70E2CB; sine_lut[85]=24'h6F5F02; sine_lut[86]=24'h6DCA0C; sine_lut[87]=24'h6C2429;
        sine_lut[88]=24'h6A6D98; sine_lut[89]=24'h68A69E; sine_lut[90]=24'h66CF80; sine_lut[91]=24'h64E888;
        sine_lut[92]=24'h62F201; sine_lut[93]=24'h60EC37; sine_lut[94]=24'h5ED77C; sine_lut[95]=24'h5CB420;
        sine_lut[96]=24'h5A8279; sine_lut[97]=24'h5842DD; sine_lut[98]=24'h55F5A4; sine_lut[99]=24'h539B2A;
        sine_lut[100]=24'h5133CC; sine_lut[101]=24'h4EBFE8; sine_lut[102]=24'h4C3FDF; sine_lut[103]=24'h49B415;
        sine_lut[104]=24'h471CEC; sine_lut[105]=24'h447ACD; sine_lut[106]=24'h41CE1E; sine_lut[107]=24'h3F1749;
        sine_lut[108]=24'h3C56BA; sine_lut[109]=24'h398CDD; sine_lut[110]=24'h36BA20; sine_lut[111]=24'h33DEF2;
        sine_lut[112]=24'h30FBC5; sine_lut[113]=24'h2E110A; sine_lut[114]=24'h2B1F35; sine_lut[115]=24'h2826B9;
        sine_lut[116]=24'h25280C; sine_lut[117]=24'h2223A5; sine_lut[118]=24'h1F19F9; sine_lut[119]=24'h1C0B82;
        sine_lut[120]=24'h18F8B8; sine_lut[121]=24'h15E214; sine_lut[122]=24'h12C810; sine_lut[123]=24'h0FAB27;
        sine_lut[124]=24'h0C8BD3; sine_lut[125]=24'h096A90; sine_lut[126]=24'h0647D9; sine_lut[127]=24'h03242B;
        sine_lut[128]=24'h000000; sine_lut[129]=24'hFCDBD5; sine_lut[130]=24'hF9B827; sine_lut[131]=24'hF69570;
        sine_lut[132]=24'hF3742D; sine_lut[133]=24'hF054D9; sine_lut[134]=24'hED37F0; sine_lut[135]=24'hEA1DEC;
        sine_lut[136]=24'hE70748; sine_lut[137]=24'hE3F47E; sine_lut[138]=24'hE0E607; sine_lut[139]=24'hDDDC5B;
        sine_lut[140]=24'hDAD7F4; sine_lut[141]=24'hD7D947; sine_lut[142]=24'hD4E0CB; sine_lut[143]=24'hD1EEF6;
        sine_lut[144]=24'hCF043B; sine_lut[145]=24'hCC210E; sine_lut[146]=24'hC945E0; sine_lut[147]=24'hC67323;
        sine_lut[148]=24'hC3A946; sine_lut[149]=24'hC0E8B7; sine_lut[150]=24'hBE31E2; sine_lut[151]=24'hBB8533;
        sine_lut[152]=24'hB8E314; sine_lut[153]=24'hB64BEB; sine_lut[154]=24'hB3C021; sine_lut[155]=24'hB14018;
        sine_lut[156]=24'hAECC34; sine_lut[157]=24'hAC64D6; sine_lut[158]=24'hAA0A5C; sine_lut[159]=24'hA7BD23;
        sine_lut[160]=24'hA57D87; sine_lut[161]=24'hA34BE0; sine_lut[162]=24'hA12884; sine_lut[163]=24'h9F13C9;
        sine_lut[164]=24'h9D0DFF; sine_lut[165]=24'h9B1778; sine_lut[166]=24'h993080; sine_lut[167]=24'h975962;
        sine_lut[168]=24'h959268; sine_lut[169]=24'h93DBD7; sine_lut[170]=24'h9235F4; sine_lut[171]=24'h90A0FE;
        sine_lut[172]=24'h8F1D35; sine_lut[173]=24'h8DAAD4; sine_lut[174]=24'h8C4A15; sine_lut[175]=24'h8AFB2E;
        sine_lut[176]=24'h89BE52; sine_lut[177]=24'h8893B2; sine_lut[178]=24'h877B7D; sine_lut[179]=24'h8675DD;
        sine_lut[180]=24'h8582FC; sine_lut[181]=24'h84A2FD; sine_lut[182]=24'h83D605; sine_lut[183]=24'h831C32;
        sine_lut[184]=24'h8275A2; sine_lut[185]=24'h81E26D; sine_lut[186]=24'h8162AB; sine_lut[187]=24'h80F66F;
        sine_lut[188]=24'h809DCA; sine_lut[189]=24'h8058CA; sine_lut[190]=24'h802779; sine_lut[191]=24'h8009DF;
        sine_lut[192]=24'h800001; sine_lut[193]=24'h8009DF; sine_lut[194]=24'h802779; sine_lut[195]=24'h8058CA;
        sine_lut[196]=24'h809DCA; sine_lut[197]=24'h80F66F; sine_lut[198]=24'h8162AB; sine_lut[199]=24'h81E26D;
        sine_lut[200]=24'h8275A2; sine_lut[201]=24'h831C32; sine_lut[202]=24'h83D605; sine_lut[203]=24'h84A2FD;
        sine_lut[204]=24'h8582FC; sine_lut[205]=24'h8675DD; sine_lut[206]=24'h877B7D; sine_lut[207]=24'h8893B2;
        sine_lut[208]=24'h89BE52; sine_lut[209]=24'h8AFB2E; sine_lut[210]=24'h8C4A15; sine_lut[211]=24'h8DAAD4;
        sine_lut[212]=24'h8F1D35; sine_lut[213]=24'h90A0FE; sine_lut[214]=24'h9235F4; sine_lut[215]=24'h93DBD7;
        sine_lut[216]=24'h959268; sine_lut[217]=24'h975962; sine_lut[218]=24'h993080; sine_lut[219]=24'h9B1778;
        sine_lut[220]=24'h9D0DFF; sine_lut[221]=24'h9F13C9; sine_lut[222]=24'hA12884; sine_lut[223]=24'hA34BE0;
        sine_lut[224]=24'hA57D87; sine_lut[225]=24'hA7BD23; sine_lut[226]=24'hAA0A5C; sine_lut[227]=24'hAC64D6;
        sine_lut[228]=24'hAECC34; sine_lut[229]=24'hB14018; sine_lut[230]=24'hB3C021; sine_lut[231]=24'hB64BEB;
        sine_lut[232]=24'hB8E314; sine_lut[233]=24'hBB8533; sine_lut[234]=24'hBE31E2; sine_lut[235]=24'hC0E8B7;
        sine_lut[236]=24'hC3A946; sine_lut[237]=24'hC67323; sine_lut[238]=24'hC945E0; sine_lut[239]=24'hCC210E;
        sine_lut[240]=24'hCF043B; sine_lut[241]=24'hD1EEF6; sine_lut[242]=24'hD4E0CB; sine_lut[243]=24'hD7D947;
        sine_lut[244]=24'hDAD7F4; sine_lut[245]=24'hDDDC5B; sine_lut[246]=24'hE0E607; sine_lut[247]=24'hE3F47E;
        sine_lut[248]=24'hE70748; sine_lut[249]=24'hEA1DEC; sine_lut[250]=24'hED37F0; sine_lut[251]=24'hF054D9;
        sine_lut[252]=24'hF3742D; sine_lut[253]=24'hF69570; sine_lut[254]=24'hF9B827; sine_lut[255]=24'hFCDBD5;
    end

    //---- 淡入淡出包络（8 位 0..240，用移位，无除法）----
    wire [13:0] d_in  = note_cnt;
    wire [13:0] d_out = NOTE_LEN - note_cnt;
    wire [7:0]  e_in  = (d_in  >= FADE) ? 8'd240 : {4'd0, d_in[10:3]};
    wire [7:0]  e_out = (d_out >= FADE) ? 8'd240 : {4'd0, d_out[10:3]};
    wire [7:0]  env8  = (note_cnt < FADE)       ? e_in  :
                        (note_cnt > NOTE_LEN-FADE) ? e_out : 8'd240;

    //---- 幅度：正弦(24位有符号) × 包络(9位) >> 9（含整体降半音量）----
    wire signed [23:0] sine_s = sine_lut[idx];
    wire signed [32:0] prod   = sine_s * $signed({1'b0, env8});   // 24+9=33 位
    wire        [23:0] sample = prod[32:9];                        // >>9

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc<=25'd0; note_cnt<=14'd0; note_idx<=4'd0; phase<=32'd0;
            audio_valid<=1'b0; audio_left<=24'd0; audio_right<=24'd0;
        end else begin
            audio_valid <= 1'b0;
            if (sample_now) begin
                acc <= acc + FS_HZ - CLK_HZ;
                phase <= phase + phase_step;
                audio_valid <= 1'b1;
                audio_left  <= sample;
                audio_right <= sample;
                if (note_cnt == NOTE_LEN-1) begin
                    note_cnt <= 14'd0;
                    note_idx <= (note_idx == N_NOTE-1) ? 4'd0 : (note_idx + 4'd1);
                end else
                    note_cnt <= note_cnt + 14'd1;
            end else
                acc <= acc + FS_HZ;
        end
    end
endmodule
