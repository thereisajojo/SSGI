Shader "Unlit/WorldPos"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {
        Tags
        {
            "RenderType"="Opaque"
        }
        LOD 100

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "UnityCG.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                float3 posWS : TEXCOORD2;
                float4 vertex : SV_POSITION;
                float4 posSS : TEXCOORD3;
            };

            sampler2D _MainTex;
            float4 _MainTex_ST;

            v2f vert(appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _MainTex);
                o.posWS = mul(unity_ObjectToWorld, float4(v.vertex.xyz, 1));
                o.posSS = ComputeScreenPos(o.vertex);
                return o;
            }

            fixed4 frag(v2f i) : SV_Target
            {
                float4 CS = UnityWorldToClipPos(i.posWS);
                float4 SS = ComputeScreenPos(CS);

                float2 uv0 = i.posSS.xy / i.posSS.w;
                float2 uv = SS.xy / SS.w;
                half4 col = half4(uv0, 0, 1.0);
                return col;
            }
            ENDCG
        }
    }
}