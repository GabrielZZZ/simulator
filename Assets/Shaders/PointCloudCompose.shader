﻿/**
 * Copyright (c) 2019 LG Electronics, Inc.
 *
 * This software contains code licensed as described in LICENSE.
 *
 */

Shader "Simulator/PointCloud/HDRP/Compose"
{
    HLSLINCLUDE

    #pragma vertex Vert

    #pragma target 4.5
    #pragma only_renderers d3d11 ps4 xboxone vulkan metal switch

    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/RenderPipeline/RenderPass/CustomPass/CustomPassCommon.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/NormalBuffer.hlsl"

    #pragma multi_compile_local _ _PC_LINEAR_DEPTH
    #pragma multi_compile _ _PC_TARGET_GBUFFER

    Texture2D _ColorTex;
    SamplerState sampler_ColorTex;
    
    Texture2D _NormalDepthTex;
    SamplerState sampler_NormalDepthTex;

    TEXTURE2D_X(_OriginalDepth);

    float4 _SRMulVec;

    float3 EncodeFloatRGB(float v)
    {
        float4 kEncodeMul = float4(1.0, 255.0, 65025.0, 16581375.0);
        float kEncodeBit = 1.0/255.0;
        float4 enc = kEncodeMul * v * 0.5;
        enc = frac (enc);
        enc -= enc.yzww * kEncodeBit;
        return enc.xyz;
    }

    float3 UnpackRGB(float2 packed)
    {
        uint r = asuint(packed.r);
        return float3(f16tof32(r), packed.g, f16tof32(r >> 16));
        // return float3(packed, 0);
    }

    void DefaultComposePass(Varyings varyings,
    #ifdef _PC_TARGET_GBUFFER
        out float4 outGBuffer0 : SV_Target0, 
        out float4 outGBuffer1 : SV_Target1,
        out float4 outGBuffer2 : SV_Target2,
        out float4 outGBuffer3 : SV_Target3,
    #else
        out float4 outColor : SV_Target0,
    #endif
        out float depth : SV_Depth)
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(varyings);
        float camDepth = LOAD_TEXTURE2D_X_LOD(_OriginalDepth, varyings.positionCS.xy, 0).r;
        PositionInputs posInput = GetPositionInput(varyings.positionCS.xy, _ScreenSize.zw, depth, UNITY_MATRIX_I_VP, UNITY_MATRIX_V);

        float2 insetSS = posInput.positionSS;
        insetSS.x = insetSS.x * _SRMulVec.x + _SRMulVec.y;
        insetSS.y = insetSS.y * _SRMulVec.x + _SRMulVec.z;

        float4 pcPacked = _ColorTex.Load(int3(insetSS, 0));
        float4 pcNormalDepth = _NormalDepthTex.Load(int3(insetSS, 0));

        #ifdef _PC_LINEAR_DEPTH
            float linearDepth = 1.0 - pcPacked.w;
            float eyeDepth = (1 / (linearDepth) - _ZBufferParams.y) / _ZBufferParams.x;
        #else
            float eyeDepth = pcPacked.w;
        #endif

        if (eyeDepth <= camDepth)
            discard;
        
        depth = eyeDepth;

        #ifndef _PC_TARGET_GBUFFER
            outColor = float4(UnpackRGB(pcPacked.rg), 1);
        #else
            NormalData nData;
            nData.normalWS = pcNormalDepth.rgb;
            nData.perceptualRoughness = 1;

            float4 normalGBuffer;
            EncodeIntoNormalBuffer(nData, insetSS, /* out */ normalGBuffer);

            float3 color = UnpackRGB(pcPacked.rg);

            outGBuffer0 = float4(color, 1);
            outGBuffer1 = normalGBuffer;
            outGBuffer2 = float4(0, 0, 0, 0);
            outGBuffer3 = float4(color * 0.1, 0);
        #endif
    }

    void LidarComposePass(Varyings varyings, out float4 outColor : SV_Target0)
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(varyings);
        float camDepth = LOAD_TEXTURE2D_X_LOD(_OriginalDepth, varyings.positionCS.xy, 0).r;
        PositionInputs posInput = GetPositionInput(varyings.positionCS.xy, _ScreenSize.zw, camDepth, UNITY_MATRIX_I_VP, UNITY_MATRIX_V);

        float2 insetSS = posInput.positionSS;
        insetSS.x = insetSS.x * _SRMulVec.x + _SRMulVec.y;
        insetSS.y = insetSS.y * _SRMulVec.x + _SRMulVec.z;

        float4 pcPacked = _ColorTex.Load(int3(insetSS, 0));

        #ifdef _PC_LINEAR_DEPTH
            float linearDepth = 1.0 - pcPacked.w;
            float eyeDepth = (1 / (linearDepth) - _ZBufferParams.y) / _ZBufferParams.x;
        #else
            float linearDepth = Linear01Depth(pcPacked.w, _ZBufferParams);
            float eyeDepth = pcPacked.w;
        #endif

        // Solid render has depth data on the whole texture, which lidar will detect - discard far plane
        if (eyeDepth < camDepth || linearDepth > 0.999)
            discard;

        // Lidar uses unusual depth format - just calculate it here
        float2 positionNDC = varyings.positionCS.xy * _ScreenSize.zw;
        float3 positionWS = ComputeWorldSpacePosition(positionNDC, eyeDepth, UNITY_MATRIX_I_VP);
        float lidarDepth = length(GetPrimaryCameraPosition() - positionWS);

        float4 pcColor = float4(UnpackRGB(pcPacked.rg), 1);
        float intensity = (pcColor.r + pcColor.g + pcColor.b) / 3;

        outColor = float4(EncodeFloatRGB(lidarDepth * _ProjectionParams.w), intensity);
    }

    void DebugComposePass(Varyings varyings, out float4 outColor : SV_Target0)
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(varyings);
        PositionInputs posInput = GetPositionInput(varyings.positionCS.xy, _ScreenSize.zw, 0, UNITY_MATRIX_I_VP, UNITY_MATRIX_V);

        float2 insetSS = posInput.positionSS;
        // insetSS.x = insetSS.x * _SRMulVec.x + _SRMulVec.y;
        // insetSS.y = insetSS.y * _SRMulVec.x + _SRMulVec.z;
        float4 pcColor = _ColorTex.Load(int3((uint2)insetSS, 0));
        // pcColor.rgb = float3(pcColor.w, pcColor.w, pcColor.w);
        // outColor = pcColor;
        float3 rgb = UnpackRGB(pcColor.rg);
        // float3 rgb = float3(pcColor.rg, 0);
        outColor = float4(rgb, 1);
    }

    ENDHLSL

    Properties
    {
        [HideInInspector] _StencilRefGBuffer("_StencilRefGBuffer", Int) = 2
        [HideInInspector] _StencilWriteMaskGBuffer("_StencilWriteMaskGBuffer", Int) = 3
    }

    SubShader
    {
        Pass
        {
            Stencil
            {
                WriteMask [_StencilWriteMaskGBuffer]
                Ref [_StencilRefGBuffer]
                Comp Always
                Pass Replace
            }

            Name "Point Cloud Default Compose"

            ZWrite On
            ZTest Always
            Blend One Zero
            Cull Off

            HLSLPROGRAM
                #pragma fragment DefaultComposePass
            ENDHLSL
        }

        Pass
        {
            Name "Point Cloud Lidar Compose"

            ZWrite On
            ZTest Always
            Blend One Zero
            Cull Off

            HLSLPROGRAM
                #pragma fragment LidarComposePass
            ENDHLSL
        }

        Pass
        {
            Name "Point Cloud Debug Compose"

            ZWrite Off
            ZTest Always
            Blend One Zero
            Cull Off

            HLSLPROGRAM
                #pragma fragment DebugComposePass
            ENDHLSL
        }
    }
    Fallback Off
}
