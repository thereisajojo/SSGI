Shader "Hidden/SSGI"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {
        Cull Off ZWrite Off ZTest Always
        
        HLSLINCLUDE
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
            float4 positionHCS : SV_POSITION;
        };

        TEXTURE2D(_MainTex);
        SAMPLER(sampler_MainTex);
        float4 _MainTex_TexelSize;

        v2f vert(appdata v)
        {
            v2f o;
            o.positionHCS = TransformObjectToHClip(v.vertex.xyz);
            o.uv = v.uv;
            return o;
        }
        
        ENDHLSL

        Pass
        {
            Name "SSGI"
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment SSGIFrag

            #pragma multi_compile _ _SAMPLE_BACK

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Sampling/Sampling.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            static half SSAORandomUV[40] =
            {
                0.00000000, // 00
                0.33984375, // 01
                0.75390625, // 02
                0.56640625, // 03
                0.98437500, // 04
                0.07421875, // 05
                0.23828125, // 06
                0.64062500, // 07
                0.35937500, // 08
                0.50781250, // 09
                0.38281250, // 10
                0.98437500, // 11
                0.17578125, // 12
                0.53906250, // 13
                0.28515625, // 14
                0.23137260, // 15
                0.45882360, // 16
                0.54117650, // 17
                0.12941180, // 18
                0.64313730, // 19

                0.92968750, // 20
                0.76171875, // 21
                0.13333330, // 22
                0.01562500, // 23
                0.00000000, // 24
                0.10546875, // 25
                0.64062500, // 26
                0.74609375, // 27
                0.67968750, // 28
                0.35156250, // 29
                0.49218750, // 30
                0.12500000, // 31
                0.26562500, // 32
                0.62500000, // 33
                0.44531250, // 34
                0.17647060, // 35
                0.44705890, // 36
                0.93333340, // 37
                0.87058830, // 38
                0.56862750, // 39
            };

            TEXTURE2D(_OnlyColorTexture); SAMPLER(sampler_OnlyColorTexture);
            // TEXTURE2D(_LastSSGI); SAMPLER(sampler_LastSSGI);

            float _StepScale;
            float _Thickness;
            int _FrameIndex;
            
            float4 _CameraViewTopLeftCorner;
            float4 _CameraViewXExtent;
            float4 _CameraViewYExtent;
            float4 _ProjectionParams2;
            float4x4 _SSGI_MATRIX_VP;
            // float4x4 _TAA_MATRIX_VP;

            float4 _AmbientSH[7];

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

            half GetRandomUVForSSAO(float u, int sampleIndex)
            {
                return SSAORandomUV[u * 20 + sampleIndex];
            }

            half2 CosSin(half theta)
            {
                half sn, cs;
                sincos(theta, sn, cs);
                return half2(cs, sn);
            }

            half3 PickSamplePoint(float2 uv, int sampleIndex)
            {
                const float2 positionSS = float2(uv * _ScaledScreenParams.xy);
                const half gn = half(InterleavedGradientNoise(positionSS, sampleIndex/*_FrameIndex*/));

                const half u = frac(GetRandomUVForSSAO(half(0.0), sampleIndex) + gn) * half(2.0) - half(1.0);
                const half theta = (GetRandomUVForSSAO(half(1.0), sampleIndex) + gn) * half(TWO_PI);

                return half3(CosSin(theta) * sqrt(half(1.0) - u * u), u);
            }

            // 另一种随机
            float2 HashRandom(float2 p, float sampleCount)
            {
                float3 p3 = frac(float3(p.xyx) * float3(.1031, .1030, .0973));
                p3 += dot(p3, p3.yzx + 33.33);
                float3 frameMagicScale = float3(2.083f, 4.867f, 8.65);
                p3 += sampleCount * frameMagicScale;
                return frac((p3.xx + p3.yz) * p3.zy);
            }

            float3 GetSampleDir(float2 p, uint sampleCount)
            {
                float2 u = HashRandom(p, sampleCount);

                return SampleHemisphereCosine(u.x, u.y);
            }

            #define RayCount 3
            #define MaxStep 16
            half4 SSGIFrag(v2f input) : SV_Target
            {
                float2 UV = input.uv;

                float3 vnormal = SampleSceneNormals(UV);
                float rawDepth = SampleSceneDepth(UV);

                // 忽略天空盒
            #if UNITY_REVERSED_Z
                if(rawDepth < 0.001)
            #else
                if(rawDepth > 0.999)
            #endif
                {
                    return half4(0,0,0,0);
                }
                
                float linearDepth = LinearEyeDepth(rawDepth, _ZBufferParams);
                float3 vpos = ReconstructViewPos(UV, linearDepth);

                half4 gi = half4(0,0,0,0);
                for (int i = 0; i < RayCount; i++)
                {
                    // float3 rayDir = normalize(GetSampleDir(vpos, 6));
                    float3 rayDir = PickSamplePoint(input.uv, i);
                    rayDir = faceforward(rayDir, -vnormal, rayDir);
                    half NdotL = max(0, dot(rayDir, vnormal));

                    bool hit = false;
                    half4 sampleCol = half4(0,0,0,0);

                    // UNITY_LOOP （不展开循环帧率会下降）
                    for (int j = 0; j < MaxStep; j++)
                    {
                        float3 vpos2 = vpos + rayDir * _StepScale * (i + 1);

                        float2 uv2;
                        float stepDepth;
                        ReconstructUVAndDepth(vpos2, uv2, stepDepth);
                        float stepRawDepth = SampleSceneDepth(uv2);
                        float stepSurfaceDepth = LinearEyeDepth(stepRawDepth, _ZBufferParams);
                        if (stepSurfaceDepth < stepDepth)
                        {
                        #if defined(_SAMPLE_BACK)
                            half4 col = SAMPLE_TEXTURE2D_LOD(_OnlyColorTexture, sampler_OnlyColorTexture, uv2, 0);
                            sampleCol = col * NdotL;
                            hit = true;
                            break;
                        #else
                            float3 sampleNormal = SampleSceneNormals(uv2);
                            bool valid = dot(vnormal, sampleNormal) <= 0; // 忽略同向法线
                            if(valid)
                            {
                                half4 col = SAMPLE_TEXTURE2D_LOD(_OnlyColorTexture, sampler_OnlyColorTexture, uv2, 0);
                                sampleCol = col * NdotL;
                            }
                            hit = valid;
                            break;
                        #endif
                            
                        }
                    }

                    if(!hit)
                    {
                        sampleCol = half4(SampleSH9(_AmbientSH, vnormal), 1);
                    }
                    
                    gi += sampleCol;
                }

                gi /= RayCount;
                
                // TAA
                /*
                float4 lastUV = mul(_TAA_MATRIX_VP, float4(vpos, 1));
                lastUV.xyz /= lastUV.w;
                lastUV.xy = lastUV * 0.5 + 0.5;
                // lastUV.y = 1 - lastUV.y;
                half4 lastGI = SAMPLE_TEXTURE2D(_LastSSGI, sampler_LastSSGI, lastUV);
                float zDiff = abs(LinearEyeDepth(lastGI.a, _ZBufferParams) - linearDepth);
                zDiff = exp(-zDiff);
                // gi.rgb = lerp(gi.rgb, lastGI.rgb, clamp(zDiff, 0, 0.95));
                gi.rgb = lerp(gi.rgb, lastGI.rgb, 0.95);
                */
                
                return gi;
            }
            ENDHLSL
        }

        Pass
        {
            Name "Bilateral_Blur"
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag_bilateralnormal
            // #pragma fragment frag_bilateralcolor

            float _BilateralFilterFactor;
            float4 _BlurRadius;
            
            // #include "UnityCG.cginc"
            half LinearRgbToLuminance(half3 linearRgb)
            {
                return dot(linearRgb, half3(0.2126729f, 0.7151522f, 0.0721750f));
            }
            
            half CompareColor(half4 col1, half4 col2)
            {
                float l1 = LinearRgbToLuminance(col1.rgb);
                float l2 = LinearRgbToLuminance(col2.rgb);
                return smoothstep(_BilateralFilterFactor, 1.0, 1.0 - abs(l1 - l2));
            }

            half CompareNormal(float3 normal1, float3 normal2)
            {
                return smoothstep(_BilateralFilterFactor, 1.0, dot(normal1, normal2));
            }

            void SampleColorAndNormal(float2 uv, out half4 color, out float3 normal)
            {
                color = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv);
                normal = SampleSceneNormals(uv);
            }

            half4 frag_bilateralnormal(v2f i) : SV_Target
            {
                float2 delta = _MainTex_TexelSize.xy * _BlurRadius.xy;;
                half4 col, col0a, col0b, col1a, col1b, col2a, col2b;
                float3 nor, nor0a, nor0b, nor1a, nor1b, nor2a, nor2b;
                SampleColorAndNormal(i.uv, col, nor);
                SampleColorAndNormal(i.uv - delta, col0a, nor0a);
                SampleColorAndNormal(i.uv + delta, col0b, nor0b);
                SampleColorAndNormal(i.uv - 2.0 * delta, col1a, nor1a);
                SampleColorAndNormal(i.uv + 2.0 * delta, col1b, nor1b);
                SampleColorAndNormal(i.uv - 3.0 * delta, col2a, nor2a);
                SampleColorAndNormal(i.uv + 3.0 * delta, col2b, nor2b);

                half w = 0.37004405286;
                half w0a = CompareNormal(nor, nor0a) * 0.31718061674;
                half w0b = CompareNormal(nor, nor0b) * 0.31718061674;
                half w1a = CompareNormal(nor, nor1a) * 0.19823788546;
                half w1b = CompareNormal(nor, nor1b) * 0.19823788546;
                half w2a = CompareNormal(nor, nor2a) * 0.11453744493;
                half w2b = CompareNormal(nor, nor2b) * 0.11453744493;

                half3 result = w * col.rgb;
                result += w0a * col0a.rgb;
                result += w0b * col0b.rgb;
                result += w1a * col1a.rgb;
                result += w1b * col1b.rgb;
                result += w2a * col2a.rgb;
                result += w2b * col2b.rgb;

                result /= w + w0a + w0b + w1a + w1b + w2a + w2b;

                return half4(result, col.a);
            }

            half4 frag_bilateralcolor(v2f i) : SV_Target
            {
                float2 delta = _MainTex_TexelSize.xy * _BlurRadius.xy;
                half4 col = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv);
                half4 col0a = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv - delta);
                half4 col0b = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv + delta);
                half4 col1a = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv - 2.0 * delta);
                half4 col1b = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv + 2.0 * delta);
                half4 col2a = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv - 3.0 * delta);
                half4 col2b = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv + 3.0 * delta);

                half w = 0.37004405286;
                half w0a = CompareColor(col, col0a) * 0.31718061674;
                half w0b = CompareColor(col, col0b) * 0.31718061674;
                half w1a = CompareColor(col, col1a) * 0.19823788546;
                half w1b = CompareColor(col, col1b) * 0.19823788546;
                half w2a = CompareColor(col, col2a) * 0.11453744493;
                half w2b = CompareColor(col, col2b) * 0.11453744493;

                half3 result = w * col.rgb;
                result += w0a * col0a.rgb;
                result += w0b * col0b.rgb;
                result += w1a * col1a.rgb;
                result += w1b * col1b.rgb;
                result += w2a * col2a.rgb;
                result += w2b * col2b.rgb;

                result /= w + w0a + w0b + w1a + w1b + w2a + w2b;

                return half4(result, col.a);
            }
            ENDHLSL
        }

        Pass
        {
            Name "Gaussian_Blur"

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag_Gaussian

            float _GIFilterSize;

            half4 frag_Gaussian(v2f input) : SV_Target
            {
            #ifdef _HIGHT_QUALITY
                #define FILTER_COUNT 9
                const float2 offsets[FILTER_COUNT] = { float2(0.0, 0.0), float2(-1, 0.0), float2(1, 0.0), float2(0.0, -1), float2(0.0, 1),
                float2(1, 1), float2(1, -1), float2(-1, 1), float2(-1, -1) };
            #else
                #define FILTER_COUNT 5
                const float2 offsets[FILTER_COUNT] = {float2(1.0, 0), float2(0, -1.0), float2(0, 1.0), float2(-1.0, 0), float2(0.0, 0)};
            #endif
                float4 color = 0;
                float w = 0;
                float depth = SampleSceneDepth(input.uv).r;
                float3 normalWS = SampleSceneNormals(input.uv);
                for (int i = 0; i < FILTER_COUNT; i++)
                {
                    float2 offset = _MainTex_TexelSize.xy * offsets[i] * _GIFilterSize; //每次滤波使用越来越大的_GIFilterSize
                    float4 textureColor = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.uv + offset.xy);
                    float deviceDepth = SampleSceneDepth(input.uv + offset.xy).r;
                    float3 sampleNormalWS = SampleSceneNormals(input.uv + offset.xy);
                    float weight = 1.0 / float(FILTER_COUNT);
                    float diffDepth = LinearEyeDepth(depth, _ZBufferParams) - LinearEyeDepth(deviceDepth, _ZBufferParams);
                    diffDepth = abs(diffDepth) * float(-5.0);
                    diffDepth = saturate(exp(diffDepth));
                    float normalDiff = max(0.0, dot(normalWS, sampleNormalWS));
                    weight = weight * diffDepth * normalDiff;
                    color.xyz += textureColor.xyz * weight;
                    w += weight;
                }
                return float4(color.xyz / max(0.001, w), 1);
            }
            ENDHLSL
        }
    }
}