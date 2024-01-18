Shader "Hidden/SSR"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {
        // No culling or depth
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment SSRFrag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareNormalsTexture.hlsl"

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                float4 vertex : SV_POSITION;
            };

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = TransformObjectToHClip(v.vertex.xyz);
                o.uv = v.uv;
                return o;
            }

            TEXTURE2D(_CameraOpaqueTexture);
            SAMPLER(sampler_CameraOpaqueTexture);

            float _StepScale;
            float4 _CameraViewTopLeftCorner;
            float4 _CameraViewXExtent;
            float4 _CameraViewYExtent;
            float4 _ProjectionParams2;
            float4x4 _SSGI_MATRIX_VP;

            // 还原世界空间下，相对于相机的位置  
            half3 ReconstructViewPos(float2 uv, float linearEyeDepth)
            {
                // Screen is y-inverted
                uv.y = 1.0 - uv.y;

                float zScale = linearEyeDepth * _ProjectionParams2.x; // divide by near plane  
                float3 viewPos = _CameraViewTopLeftCorner.xyz + _CameraViewXExtent.xyz * uv.x + _CameraViewYExtent.xyz * uv.y;
                viewPos *= zScale;
                return viewPos;
            }
            
            // 从视角空间顶点中还原屏幕空间uv和深度
            void ReconstructUVAndDepth(float3 wpos, out float2 uv, out float depth)
            {
                float4 cpos = mul(_SSGI_MATRIX_VP, float4(wpos, 1.0));
                // uv = float2(cpos.x, cpos.y * _ProjectionParams.x) / cpos.w * 0.5 + 0.5;
                uv = float2(cpos.x, cpos.y) / cpos.w * 0.5 + 0.5;
                depth = cpos.w;
            }

            #define MAXDISTANCE 15
            #define STEP_COUNT 100
            half4 SSRFrag (v2f input) : SV_Target
            {
                float2 UV = input.uv;
                
                float rawDepth = SampleSceneDepth(UV);
                float linearDepth = LinearEyeDepth(rawDepth, _ZBufferParams);
                float3 vpos = ReconstructViewPos(UV, linearDepth);
                float3 vnormal = SampleSceneNormals(UV);
                float3 vDir = normalize(vpos);
                float3 rDir = normalize(reflect(vDir, vnormal));

                // float2 uv;
                // float depth;
                // float3 wpos = vpos + _WorldSpaceCameraPos;
                // ReconstructUVAndDepth(vpos, uv, depth);
                // uv.y = 1 - uv.y;
                // float sampleDepth = SampleSceneDepth(uv);
                // sampleDepth = LinearEyeDepth(sampleDepth, _ZBufferParams);
                // return half4(abs(sampleDepth - depth) * 100,0,0,0);

                UNITY_LOOP
                for (int i = 0; i < STEP_COUNT; i++)
                {
                    float3 vpos2 = vpos + rDir * _StepScale * (i + 1);
                    float2 uv2;
                    float stepDepth;
                    ReconstructUVAndDepth(vpos2, uv2, stepDepth);
                    uv2.y = 1 - uv2.y;
                    float stepRawDepth = SampleSceneDepth(uv2);
                    float stepSurfaceDepth = LinearEyeDepth(stepRawDepth, _ZBufferParams);
                    // if (stepSurfaceDepth > stepDepth && stepDepth > stepSurfaceDepth + _Thickness)
                    if(stepSurfaceDepth < stepDepth)
                        return SAMPLE_TEXTURE2D(_CameraOpaqueTexture, sampler_CameraOpaqueTexture, uv2);
                }
                return half4(0.2, 0.3, 0.4, 1.0);
                // return half4(wpos, 1);
            }
            ENDHLSL
        }
    }
}
